import Foundation

/// Local prepared daily reports. A stable full-day scan range enables the
/// incremental parser cache; the report itself is clipped to its capture time.
public actor DailyActivityQuery {
    public static let shared = DailyActivityQuery()
    private let roots: AgentLogRoots
    private let scans: CoachingQueryStore
    private let desktop: DesktopAppActivityStore
    private let files: ReportFileStore
    private var pending: [String: Task<DailyReportDraft, Error>] = [:]
    private var memory: [String: DailyReportDraft] = [:]

    public init(roots: AgentLogRoots = .current, scans: CoachingQueryStore = .shared,
                desktop: DesktopAppActivityStore = .local, cacheDirectory: URL? = nil) {
        self.roots = roots; self.scans = scans; self.desktop = desktop
        self.files = ReportFileStore(root: cacheDirectory ?? FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("com.vtamm.agentwatch/daily-activity-v2"))
    }
    private func key(_ profile: EmployeeProfile, _ period: DailyReportPeriod) throws -> String {
        ReportEncoding.digest(try ReportEncoding.encode(profile)) + "-" + ReportEncoding.digest(Data([roots.claudeProjects, roots.claudeDesktop, roots.codexSessions, roots.codexArchived, roots.piSessions].joined(separator: "\n").utf8)) + "-" + String(Int(period.start.timeIntervalSince1970))
    }
    public func cached(profile: EmployeeProfile, day: Date, now: Date = Date()) throws -> DailyReportDraft? {
        let period = try DailyReportPeriod(day: day, timeZone: profile.timeZone, cutoff: now)
        let key = try key(profile, period)
        if let report = memory[key] { return report }
        let url = files.root.appendingPathComponent(key + ".json")
        guard let data = try? Data(contentsOf: url), let report = try? ReportEncoding.decode(DailyReportDraft.self, from: data),
              report.employee == profile, report.period.start == period.start else { return nil }
        remember(report, key: key)
        return report
    }
    public func refresh(profile: EmployeeProfile, day: Date, now: Date = Date()) async throws -> DailyReportDraft {
        let period = try DailyReportPeriod(day: day, timeZone: profile.timeZone, cutoff: now)
        let key = try key(profile, period)
        if let task = pending[key] { return try await task.value }
        let roots = roots, scans = scans, desktop = desktop
        let task = Task.detached(priority: .utility) {
            let scan = await CoachingScan.scan(in: period.range, roots: roots, store: scans)
            try Task.checkCancellation()
            var warnings: [String] = []
            let activity: DesktopActivityReport?
            do { activity = try desktop.report(employeeID: profile.employeeID, period: period) }
            catch { activity = nil; warnings.append("Chưa đọc được lịch sử ứng dụng.") }
            var report = AutomaticDailyReport.build(employee: profile, period: period, scan: scan, desktop: activity)
            report.warnings += warnings
            try ReportValidator.validate(report)
            return report
        }
        pending[key] = task
        do {
            let report = try await task.value
            pending[key] = nil
            try files.transaction { try files.write(ReportEncoding.encode(report), to: files.root.appendingPathComponent(key + ".json")) }
            remember(report, key: key)
            return report
        } catch { pending[key] = nil; throw error }
    }
    private func remember(_ report: DailyReportDraft, key: String) {
        if memory.count >= 8 { memory.removeAll() }
        memory[key] = report
    }
}
