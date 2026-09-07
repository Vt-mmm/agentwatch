import SwiftUI
import AppKit
import AgentWatchCore

struct AutomaticDailyReportExportButton: View {
    let day: Date
    @State private var busy = false
    @State private var progress = ""
    @State private var output: URL?
    @State private var draft: DailyReportDraft?
    private enum Presentation: Identifiable {
        case google
        case report(DailyReportDraft, ReportSnapshot?)
        var id: String { switch self { case .google: "google"; case .report(let draft, let snapshot): snapshot?.id ?? draft.reportID } }
    }
    @State private var presentation: Presentation?
    @State private var history: [ReportSnapshot] = []
    @State private var error: String?
    @State private var collector = DesktopAppActivityCollector.shared
    var body: some View {
        VStack(alignment: .trailing, spacing: 5) {
            HStack {
                if let output { Button("Mở report") { NSWorkspace.shared.open(output) } }
                if let draft { Button("Gửi report…") { presentation = .report(draft, nil) }.disabled(busy) }
                if !history.isEmpty {
                    Menu("Report đã chốt") {
                        ForEach(history) { saved in
                            Button("Bản \(saved.revision) · chốt \(DailyReportRenderer.dateLabel(saved.report.period.cutoff, zone: saved.report.period.timeZone, format: "HH:mm:ss"))") {
                                presentation = .report(saved.report, saved)
                            }
                        }
                    }.disabled(busy)
                }
                Button("Kết nối Google…") { presentation = .google }.disabled(busy)
                Button(busy ? "Đang tạo report…" : "Xuất report ngày") { export() }
                    .buttonStyle(.borderedProminent).disabled(busy)
            }
            Text("PDF gồm nội dung prompt đã che mẫu thông tin xác thực, công cụ và lịch sử ứng dụng.").font(.caption).foregroundStyle(.secondary)
            Text(collector.status).font(.caption).foregroundStyle(collector.error == nil ? Color.secondary : Color.red)
            HStack {
                Text(SupervisorLockStore.shared.loginItemStatus).font(.caption).foregroundStyle(.secondary)
                Button("Cài đặt tự mở") { SupervisorLockStore.shared.openLoginSettings() }.font(.caption)
            }
            if let collectionError = collector.error { Text("Ghi nhận ứng dụng có lỗi: " + collectionError).font(.caption).foregroundStyle(.red) }
            if busy { Text(progress).font(.caption).foregroundStyle(.secondary) }
            if let output, !busy { Text("Đã lưu: " + output.lastPathComponent).font(.caption).textSelection(.enabled) }
            if let error { Text(error).font(.caption).foregroundStyle(.red) }
        }
        .sheet(item: $presentation, onDismiss: loadHistory) { value in
            switch value {
            case .google: GoogleSetupView()
            case .report(let draft, let snapshot): AutomaticReportDeliveryView(draft: draft, savedSnapshot: snapshot)
            }
        }
        .onAppear { loadHistory() }
        .onChange(of: day) { _, _ in output = nil; draft = nil; loadHistory() }
    }
    private func loadHistory() {
        guard let identity = SupervisorLockStore.shared.reportIdentity else { history = []; return }
        do {
            history = try ReportSnapshotStore.local.history().filter {
                $0.report.employee.employeeID == identity.employeeID &&
                DailyReportRenderer.dateLabel($0.report.period.start, zone: $0.report.period.timeZone, format: "yyyy-MM-dd") ==
                DailyReportRenderer.dateLabel(day, zone: $0.report.period.timeZone, format: "yyyy-MM-dd")
            }
        } catch { self.error = error.localizedDescription }
    }
    private func export() {
        guard let identity = SupervisorLockStore.shared.reportIdentity else {
            error = "Nhập key mở app trước khi xuất report."; return
        }
        busy = true; error = nil; output = nil; draft = nil; progress = "Đang chuẩn bị dữ liệu theo ngày…"
        let selectedDay = day
        let defaults = UserDefaults.standard
        let organization = defaults.string(forKey: "dailyReport.organizationID")?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let zone = defaults.string(forKey: "dailyReport.timeZone") ?? "Asia/Ho_Chi_Minh"
        let profile = EmployeeProfile(organizationID: organization.isEmpty ? "Chưa cấu hình tổ chức" : organization,
            employeeID: identity.employeeID, displayName: identity.name, timeZone: zone)
        Task {
            do {
                await DesktopAppActivityCollector.shared.flush()
                let collectionError = DesktopAppActivityCollector.shared.error
                let period = try DailyReportPeriod(day: selectedDay, timeZone: zone, cutoff: Date())
                let scan = await CoachingScan.scan(in: period.scanRange, allowRecentGrowth: false, progress: { done, total in
                    await MainActor.run { progress = "Đã đọc \(done)/\(total) file log…" }
                })
                progress = "Đang tổng hợp công việc, ứng dụng và tạo PDF…"
                let result = try await Task.detached(priority: .userInitiated) {
                    var extraWarnings: [String] = []
                    let projects = Set(scan.sessions.filter { $0.source == .piagent && $0.projectDisplay.hasPrefix("/") }.map(\.projectDisplay))
                    let journals = projects.sorted().compactMap { path -> PiTaskJournalResult? in
                        let project = URL(fileURLWithPath: path)
                        guard FileManager.default.fileExists(atPath: project.appendingPathComponent(".pi/piagent-state/task-journal/events.jsonl").path) else { return nil }
                        return PiTaskJournal.read(project: project, period: period)
                    }
                    let desktop: DesktopActivityReport?
                    do { desktop = try DesktopAppActivityStore.local.report(employeeID: profile.employeeID, period: period) }
                    catch { desktop = nil; extraWarnings.append("Chưa tổng hợp được lịch sử ứng dụng: " + error.localizedDescription) }
                    var quotas: [QuotaSnapshot] = []
                    do { quotas = try QuotaSnapshotStore.local.load().filter { period.contains($0.capturedAt) } }
                    catch { extraWarnings.append("Chưa đọc được quota đã lưu.") }
                    var report = AutomaticDailyReport.build(employee: profile, period: period, scan: scan, journals: journals, quota: quotas, desktop: desktop)
                    if let collectionError { extraWarnings.append("Thu thập ứng dụng có lỗi: " + collectionError) }
                    report.warnings += extraWarnings
                    try ReportValidator.validate(report)
                    let directory = URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("Documents/AgentWatch Reports")
                    return (try AutomaticDailyReport.savePDF(report, directory: directory), report)
                }.value
                let url = result.0
                output = url; draft = result.1
                SupervisorLockStore.shared.recordReportExport(format: "automatic-pdf", scope: .day(selectedDay), url: url)
            } catch {
                self.error = error.localizedDescription
                SupervisorLockStore.shared.recordReportExportFailure(format: "automatic-pdf", scope: .day(selectedDay), error: error)
            }
            busy = false
        }
    }
}
