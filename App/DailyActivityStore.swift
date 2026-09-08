import Foundation
import Observation
import AgentWatchCore

@Observable @MainActor
final class DailyActivityStore {
    static let shared = DailyActivityStore()
    var day = Date()
    var report: DailyReportDraft?
    var busy = false
    var error: String?
    private var loop: Task<Void, Never>?
    private var selection: Task<Void, Never>?
    private var generation = UUID()
    private var followsToday = true
    static var profile: EmployeeProfile? {
        guard let identity = SupervisorLockStore.shared.reportIdentity else { return nil }
        let defaults = UserDefaults.standard
        let organization = defaults.string(forKey: "dailyReport.organizationID")?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return EmployeeProfile(organizationID: organization.isEmpty ? "Chưa cấu hình tổ chức" : organization,
            employeeID: identity.employeeID, displayName: identity.name,
            timeZone: defaults.string(forKey: "dailyReport.timeZone") ?? "Asia/Ho_Chi_Minh")
    }
    func start() {
        guard loop == nil else { return }
        select(day)
        loop = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(60))
                guard !Task.isCancelled, let self else { return }
                if self.followsToday, !ReportTime.calendar.isDate(self.day, inSameDayAs: Date()) { self.select(Date()) }
                else { self.update() }
            }
        }
    }
    func select(_ date: Date) {
        day = date
        followsToday = ReportTime.calendar.isDate(date, inSameDayAs: Date())
        report = nil
        update(restore: true)
    }
    func update(restore: Bool = false) {
        if busy && !restore { return }
        selection?.cancel(); generation = UUID()
        let version = generation, selected = day
        guard let profile = Self.profile else { report = nil; busy = false; return }
        busy = true; error = nil
        selection = Task {
            do {
                if restore, let cached = try await DailyActivityQuery.shared.cached(profile: profile, day: selected),
                   !Task.isCancelled, generation == version { report = cached }
                await DesktopAppActivityCollector.shared.flush()
                let fresh = try await DailyActivityQuery.shared.refresh(profile: profile, day: selected)
                guard !Task.isCancelled, generation == version else { return }
                report = fresh
            } catch { if generation == version { self.error = error.localizedDescription } }
            if generation == version { busy = false }
        }
    }
}
