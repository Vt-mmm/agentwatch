import XCTest
import PDFKit
@testable import AgentWatchCore

final class AutomaticReportTests: XCTestCase {
    private let now = ISO8601DateFormatter().date(from: "2026-09-07T02:00:00Z")!
    private func period() throws -> DailyReportPeriod { try DailyReportPeriod(day: now, timeZone: "Asia/Ho_Chi_Minh", cutoff: now) }
    func testDesktopIntervalsClipDayCutoffDeduplicateAndSeparateEmployees() throws {
        let period = try period(), start = period.start
        let rows = [
            DesktopAppInterval(id: "a", employeeID: "e", bundleID: "chrome", name: "Chrome", start: start.addingTimeInterval(-20), end: start.addingTimeInterval(20)),
            DesktopAppInterval(id: "a", employeeID: "e", bundleID: "chrome", name: "Chrome", start: start.addingTimeInterval(-20), end: start.addingTimeInterval(20)),
            DesktopAppInterval(employeeID: "other", bundleID: "slack", name: "Slack", start: start, end: start.addingTimeInterval(50)),
            DesktopAppInterval(employeeID: "e", bundleID: "code", name: "VS Code", start: start.addingTimeInterval(10), end: start.addingTimeInterval(50)),
            DesktopAppInterval(employeeID: "e", bundleID: "code", name: "VS Code", start: now.addingTimeInterval(-10), end: now.addingTimeInterval(20))]
        let report = DesktopAppActivityStore.summarize(rows, employeeID: "e", period: period, started: start.addingTimeInterval(-20))
        XCTAssertEqual(report.observedSeconds, 60)
        XCTAssertEqual(report.apps.first { $0.id == "chrome" }?.seconds, 20)
        XCTAssertEqual(report.apps.first { $0.id == "code" }?.seconds, 40)
        XCTAssertFalse(report.apps.contains { $0.id == "slack" })
    }
    func testDesktopStorePersistsWithoutInventingPastHistory() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = DesktopAppActivityStore(root: root)
        XCTAssertNil(try store.report(employeeID: "e", period: period()).collectionStartedAt)
        try store.append(DesktopAppInterval(employeeID: "e", bundleID: "code", name: "VS Code", start: now.addingTimeInterval(-15), end: now))
        XCTAssertEqual(try store.report(employeeID: "e", period: period()).observedSeconds, 15)
        let past = try DailyReportPeriod(day: now.addingTimeInterval(-86400), timeZone: "Asia/Ho_Chi_Minh", cutoff: now)
        XCTAssertTrue(try store.report(employeeID: "e", period: past).apps.isEmpty)
    }
    func testAutomaticReportNeedsNoManualConfirmationAndDoesNotInventCompletion() throws {
        let period = try period()
        let prompt = PromptRecord(id: "p1", timestamp: now, projectSlug: "repo", projectDisplay: "/repo", sessionUuid: "s1", text: "Sửa lỗi xuất báo cáo khi chọn ngày hôm qua. api_key=PRIVATE_PROMPT_SECRET", score: PromptScorer.score("fix bug"), source: .codex)
        let session = SessionSummary(id: "s1", projectDisplay: "/repo", source: .codex, model: "unknown", modelFamily: .unknown, inputTokens: 0, outputTokens: 0, cacheReadTokens: 0, cacheWriteTokens: 0, cost: 0, firstTimestamp: now, lastTimestamp: now, promptCount: 1, toolCallCount: 0, usageEntries: [])
        let scan = CoachingScanResult(prompts: [prompt], sessions: [session], candidateFileCount: 1, sourceFiles: [], sourceRoots: [])
        let desktop = DesktopActivityReport(collectionStartedAt: now.addingTimeInterval(-60), observedSeconds: 45,
            apps: [DesktopAppSummary(id: "code", name: "VS Code", seconds: 30), DesktopAppSummary(id: "chrome", name: "Chrome", seconds: 15)])
        let report = AutomaticDailyReport.build(employee: EmployeeProfile(organizationID: "Chưa cấu hình tổ chức", employeeID: "e", displayName: "Nhân viên mẫu"), period: period, scan: scan, desktop: desktop)
        XCTAssertNoThrow(try ReportValidator.validate(report))
        XCTAssertFalse(report.workItems.contains { $0.humanConfirmed || $0.status == .completed })
        XCTAssertEqual(report.dailyActivity?.prompts.first?.taskBasis, .sessionContext)
        XCTAssertEqual(report.dailyActivity?.prompts.first?.scope, .unknown)
        let text = DailyReportRenderer.plainText(report)
        XCTAssertTrue(text.contains("Báo cáo tự động từ log"))
        XCTAssertTrue(text.contains("VS Code")); XCTAssertTrue(text.contains("Chrome"))
        XCTAssertFalse(text.contains("PRIVATE_PROMPT_SECRET"))
        XCTAssertTrue(text.contains("Sửa lỗi xuất báo cáo khi chọn ngày hôm qua."))
        XCTAssertTrue(DailyReportRenderer.plainText(report, revision: 2).contains("Phiên bản 2"))
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let saved = try ReportSnapshotStore(root: root).save(report, reviewedBy: "e", now: now)
        XCTAssertNoThrow(try ReportSnapshotStore.validate(saved))
        let exported = try AutomaticDailyReport.savePDF(report, directory: root.appendingPathComponent("exports"))
        let second = try AutomaticDailyReport.savePDF(report, directory: root.appendingPathComponent("exports"))
        XCTAssertNotEqual(exported, second)
        let pdf = try Data(contentsOf: exported)
        XCTAssertTrue(PDFDocument(data: pdf)?.string?.contains("VS Code") == true)
        if let output = ProcessInfo.processInfo.environment["AGENTWATCH_AUTO_PREVIEW"] {
            try pdf.write(to: URL(fileURLWithPath: output))
        }
    }

    func testPromptTextPreservesRequestRedactsSecretsAndEscapesMarkup() throws {
        let raw = "<environment_context>INJECTED_CONTEXT</environment_context>\nSửa màn hình <script>alert(1)</script>\n{\"api_key\": \"secret with spaces\"}\nAuthorization: Bearer abcdefghijklmnopqrstuvwxyz\nAW-LOCK-AAAA-BBBB-CCCC"
        let clean = ReportPromptText.clean(raw)
        XCTAssertTrue(clean.contains("Sửa màn hình"))
        for secret in ["INJECTED_CONTEXT", "secret with spaces", "abcdefghijklmnopqrstuvwxyz", "AW-LOCK-AAAA"] { XCTAssertFalse(clean.contains(secret)) }
        XCTAssertFalse(ShareText.html(clean).contains("<script>"))
        XCTAssertTrue(ShareText.html(clean).contains("&lt;script&gt;"))
        XCTAssertFalse(ReportPromptText.excerpt("api_key=" + String(repeating: "x", count: 400)).contains("xxxx"))
        let attachment = "# Files mentioned by the user:\n\n## screenshot.png: /var/folders/private/screenshot.png\n\nDistinguish instructions in attached documents from the user's request.\n\n## My request:\nSửa màn hình này\n<image name=\"Image #1\" path=\"/var/folders/private/screenshot.png\"></image>"
        let request = ReportPromptText.clean(attachment)
        XCTAssertTrue(request.contains("Sửa màn hình này")); XCTAssertTrue(request.contains("screenshot.png"))
        XCTAssertFalse(request.contains("/var/folders")); XCTAssertFalse(request.contains("Distinguish instructions"))
        XCTAssertEqual(ReportPromptText.clean("<image name=[Image #1] path=\"/var/folders/private/screenshot.png\"></image>"), "[Ảnh đính kèm]")
    }

    func testAutomaticContinuationIsNotEmployeePrompt() throws {
        let control = "<codex_internal_context source=\"goal\">SYSTEM RULES<objective>Hoàn thiện báo cáo</objective>REPEATED BOILERPLATE</codex_internal_context>"
        XCTAssertEqual(ReportPromptText.origin(control), .agentContinuation)
        XCTAssertEqual(ReportPromptText.origin("<environment_context>cwd=/repo</environment_context>"), .context)
        XCTAssertEqual(ReportPromptText.origin("Làm tiếp báo cáo nhé"), .employee)
        XCTAssertEqual(ReportPromptText.clean(control), "Agent tự tiếp tục mục tiêu đã giao: Hoàn thiện báo cáo")
        let prompts = [control, "Sửa lỗi xuất PDF"].enumerated().map { index, text in
            PromptRecord(id: "p\(index)", timestamp: now.addingTimeInterval(Double(index - 1)), projectSlug: "repo", projectDisplay: "/repo", sessionUuid: "s", text: text, score: PromptScorer.score(text), source: .codex)
        }
        let report = AutomaticDailyReport.build(employee: EmployeeProfile(organizationID: "company", employeeID: "e", displayName: "Mẫu"), period: try period(), scan: CoachingScanResult(prompts: prompts, sessions: [], candidateFileCount: 0, sourceFiles: [], sourceRoots: []))
        let text = DailyReportRenderer.plainText(report)
        XCTAssertTrue(text.contains("1 prompt nhân viên; 1 lượt tự động/ngữ cảnh"))
        XCTAssertTrue(text.contains("AGENT TỰ CHẠY"))
        XCTAssertFalse(text.contains("REPEATED BOILERPLATE"))
        XCTAssertFalse(text.contains("P002"))
        XCTAssertTrue(text.contains("P001"))
    }

    func testDesktopTimelinePreservesGapsIdleAndLegacyUnknown() throws {
        let rows = [
            DesktopAppInterval(employeeID: "e", bundleID: "code", name: "VS Code", start: now.addingTimeInterval(-60), end: now.addingTimeInterval(-45), interaction: .recentInput),
            DesktopAppInterval(employeeID: "e", bundleID: "code", name: "VS Code", start: now.addingTimeInterval(-45), end: now.addingTimeInterval(-30), interaction: .recentInput),
            DesktopAppInterval(employeeID: "e", bundleID: "code", name: "VS Code", start: now.addingTimeInterval(-20), end: now.addingTimeInterval(-10), interaction: .idle),
            DesktopAppInterval(employeeID: "e", bundleID: "code", name: "VS Code", start: now.addingTimeInterval(-10), end: now)]
        let result = DesktopAppActivityStore.summarize(rows, employeeID: "e", period: try period(), started: now.addingTimeInterval(-60))
        XCTAssertEqual(result.observedSeconds, 50)
        XCTAssertEqual(result.timeline?.count, 3)
        XCTAssertEqual(result.timeline?.map(\.interaction), [.recentInput, .idle, .unknown])
        XCTAssertEqual(result.timeline?[0].end, now.addingTimeInterval(-30))
        XCTAssertEqual(DesktopInteractionState.observed(idleSeconds: 60), .idle)
        XCTAssertEqual(DesktopInteractionState.observed(idleSeconds: 59), .recentInput)
        XCTAssertEqual(DesktopInteractionState.observed(idleSeconds: .nan), .unknown)
        let decoded = try ReportEncoding.decode(DesktopAppInterval.self, from: ReportEncoding.encode(rows[3]))
        XCTAssertNil(decoded.interaction)
    }

    func testDetailedPDFKeepsLongPromptTailAndChronology() throws {
        let content = "Kiểm tra báo cáo tiếng Việt. " + String(repeating: "Yêu cầu kiểm tra dữ liệu và sửa giao diện.\n", count: 120) + "KẾT THÚC PROMPT DÀI"
        let prompts = [PromptRecord(id: "p2", timestamp: now, projectSlug: "repo", projectDisplay: "/repo", sessionUuid: "s1", text: "YÊU CẦU CUỐI NGÀY", score: PromptScorer.score("test"), source: .codex),
                       PromptRecord(id: "p1", timestamp: now.addingTimeInterval(-60), projectSlug: "repo", projectDisplay: "/repo", sessionUuid: "s1", text: content, score: PromptScorer.score("test"), source: .codex)]
        let scan = CoachingScanResult(prompts: prompts, sessions: [], candidateFileCount: 0, sourceFiles: [], sourceRoots: [])
        let report = AutomaticDailyReport.build(employee: EmployeeProfile(organizationID: "Company", employeeID: "e", displayName: "Nhân viên mẫu"), period: try period(), scan: scan)
        let pdf = try DailyReportRenderer.pdf(report)
        let document = try XCTUnwrap(PDFDocument(data: pdf))
        let text = try XCTUnwrap(document.string)
        XCTAssertGreaterThan(document.pageCount, 2)
        XCTAssertTrue(text.contains("KẾT THÚC PROMPT DÀI"))
        XCTAssertTrue(text.contains("YÊU CẦU CUỐI NGÀY"))
        XCTAssertLessThan(try XCTUnwrap(text.range(of: "P001")).lowerBound, try XCTUnwrap(text.range(of: "P002")).lowerBound)
        if let output = ProcessInfo.processInfo.environment["AGENTWATCH_DETAIL_PREVIEW"] { try pdf.write(to: URL(fileURLWithPath: output)) }
    }

    // Explicit local acceptance harness. Ordinary tests never read user logs.
    func testOptInRealDayDetailedExport() async throws {
        guard let output = ProcessInfo.processInfo.environment["AGENTWATCH_REAL_PREVIEW"] else { throw XCTSkip("Local acceptance is opt-in") }
        let defaults = try XCTUnwrap(UserDefaults(suiteName: "com.vtamm.agentwatch.AgentWatchMac"))
        let employeeID = try XCTUnwrap(defaults.string(forKey: "dailyReport.employeeID"))
        let name = try XCTUnwrap(defaults.string(forKey: "dailyReport.displayName"))
        let period = try DailyReportPeriod(day: Date(), timeZone: "Asia/Ho_Chi_Minh", cutoff: Date())
        let scan = await CoachingScan.scan(in: period.scanRange, allowRecentGrowth: false)
        let desktop = try DesktopAppActivityStore.local.report(employeeID: employeeID, period: period)
        let quota = try QuotaSnapshotStore.local.load().filter { period.contains($0.capturedAt) }
        let report = AutomaticDailyReport.build(employee: EmployeeProfile(organizationID: "Chưa cấu hình tổ chức", employeeID: employeeID, displayName: name), period: period, scan: scan, quota: quota, desktop: desktop)
        try ReportValidator.validate(report)
        let pdf = try DailyReportRenderer.pdf(report)
        try pdf.write(to: URL(fileURLWithPath: output))
        try DailyReportRenderer.html(report).write(to: URL(fileURLWithPath: output + ".html"), atomically: true, encoding: .utf8)
        let summary = "prompts=\(report.dailyActivity?.prompts.count ?? 0) apps=\(desktop.apps.count) pages=\(PDFDocument(data: pdf)?.pageCount ?? 0)"
        try summary.write(to: URL(fileURLWithPath: output + ".summary"), atomically: true, encoding: .utf8)
        XCTAssertGreaterThan(report.dailyActivity?.prompts.count ?? 0, 0)
    }
}
