import XCTest
import PDFKit
@testable import AgentWatchCore

final class ReportDailyActivityTests: XCTestCase {
    private let day = ISO8601DateFormatter().date(from: "2026-09-06T08:00:00Z")!
    private func period() throws -> DailyReportPeriod {
        try DailyReportPeriod(day: day, timeZone: "Asia/Ho_Chi_Minh", cutoff: day)
    }
    private func prompt(_ id: String, at date: Date, source: SessionSource = .piagent) -> PromptRecord {
        PromptRecord(id: id, timestamp: date, projectSlug: "repo", projectDisplay: "/repo", sessionUuid: "s1",
            text: "PRIVATE_RAW_PROMPT sk-abcdefghijklmnop123456 unrelated personal request", score: PromptScorer.score("test"), source: source)
    }
    private func report(prompts: [PromptRecord], sessions: [SessionSummary] = [], journals: [PiTaskJournalResult] = []) throws -> DailyReportDraft {
        DailyReportBuilder.build(employee: EmployeeProfile(organizationID: "Example", employeeID: "NV-1", displayName: "Nhân viên mẫu"),
            period: try period(), scan: CoachingScanResult(prompts: prompts, sessions: sessions, candidateFileCount: 0, sourceFiles: [], sourceRoots: []), journals: journals)
    }
    private func session(entries: [UsageEntry] = [], source: SessionSource = .piagent) -> SessionSummary {
        SessionSummary(id: "s1", projectDisplay: "/repo", source: source, model: "unknown", modelFamily: .unknown,
            inputTokens: 0, outputTokens: 0, cacheReadTokens: 0, cacheWriteTokens: 0, cost: 0,
            firstTimestamp: day.addingTimeInterval(-100_000), lastTimestamp: day, promptCount: 999,
            toolCallCount: 100, usageEntries: entries)
    }
    func testPromptsAndAppsRespectDayCutoffAndDeduplicateWithoutLifetimeCounts() throws {
        let range = try period()
        let inDay = prompt("p1", at: day)
        let value = try report(prompts: [inDay, inDay, prompt("old", at: range.start.addingTimeInterval(-1)),
            prompt("future", at: day.addingTimeInterval(1)), prompt("next-day", at: range.end),
            prompt("desktop", at: day, source: .desktop), prompt("codex", at: day, source: .codex)], sessions: [session()])
        let activity = try XCTUnwrap(value.dailyActivity)
        XCTAssertEqual(activity.prompts.count, 3)
        XCTAssertEqual(Set(activity.apps.map(\.name)), ["PiAgent", "Claude Desktop", "Codex"])
        XCTAssertEqual(activity.apps.first { $0.name == "PiAgent" }?.promptCount, 1)
        XCTAssertEqual(activity.apps.first { $0.name == "PiAgent" }?.sessionCount, 1)
        XCTAssertFalse(DailyReportRenderer.plainText(value).contains("999"))
        XCTAssertNoThrow(try ReportValidator.validate(value))
    }
    func testUsageOnlyAppAppearsAndTokensAreConserved() throws {
        let entries = [UsageEntry(id: "u1", sessionID: "s1", agent: "pi", provider: "openai", modelID: "unknown", timestamp: day, tokens: UsageTokens(input: 10, output: 2))]
        let value = try report(prompts: [prompt("claude", at: day, source: .cli)], sessions: [session(entries: entries)])
        let apps = try XCTUnwrap(value.dailyActivity).apps
        XCTAssertEqual(apps.first { $0.name == "PiAgent" }?.promptCount, 0)
        XCTAssertEqual(apps.first { $0.name == "PiAgent" }?.tokens, 12)
        XCTAssertEqual(apps.reduce(0) { $0 + $1.tokens }, value.totalTokens)
        XCTAssertNoThrow(try ReportValidator.validate(value))
    }
    func testJournalUsesPromptTimeAndNeverInfersBusinessScopeFromProject() throws {
        let links = [
            JournalTaskLink(projectPath: "/repo", taskID: "REP-1", taskRunID: "r1", sessionID: "s1", sessionName: "Bộ lọc", recordedAt: day.addingTimeInterval(-200), evidenceID: "j1"),
            JournalTaskLink(projectPath: "/repo", taskID: "REP-2", taskRunID: "r2", sessionID: "s1", sessionName: "Xuất report", recordedAt: day.addingTimeInterval(-50), evidenceID: "j2")]
        let journal = PiTaskJournalResult(links: links, evidence: [], warnings: [], manifest: SourceFileManifest.inspect(URL(fileURLWithPath: "/nonexistent-synthetic-journal")))
        let value = try report(prompts: [prompt("before", at: day.addingTimeInterval(-300)), prompt("first", at: day.addingTimeInterval(-100)), prompt("second", at: day)], sessions: [session()], journals: [journal])
        let rows = try XCTUnwrap(value.dailyActivity).prompts
        XCTAssertNil(rows[0].workItemID)
        XCTAssertNotNil(rows[1].workItemID)
        XCTAssertNotEqual(rows[1].workItemID, rows[2].workItemID)
        XCTAssertEqual(rows[2].taskBasis, .taskJournal)
        XCTAssertTrue(rows.allSatisfy { $0.scope == .unknown && $0.summary.isEmpty })
        XCTAssertNoThrow(try ReportValidator.validate(value))
    }
    func testAmbiguousJournalBindingIsNotAssigned() throws {
        let links = ["A", "B"].map { JournalTaskLink(projectPath: "/repo", taskID: $0, taskRunID: $0, sessionID: "s1", sessionName: $0, recordedAt: day, evidenceID: $0) }
        let journal = PiTaskJournalResult(links: links, evidence: [], warnings: [], manifest: SourceFileManifest.inspect(URL(fileURLWithPath: "/nonexistent-synthetic-journal")))
        let value = try report(prompts: [prompt("p", at: day)], sessions: [session()], journals: [journal])
        XCTAssertNil(value.dailyActivity?.prompts.first?.workItemID)
    }
    func testScopeRequiresTaskAndReasonAndMergeInvalidatesScope() throws {
        var value = try report(prompts: [prompt("p", at: day)])
        value.workItems = [ReportWorkItem(id: "a", project: "Report", title: "Task A"), ReportWorkItem(id: "b", project: "Other", title: "Task B")]
        value.dailyActivity?.prompts[0].scope = .inScope
        XCTAssertThrowsError(try ReportValidator.validate(value))
        value.dailyActivity?.prompts[0].workItemID = "a"
        value.dailyActivity?.prompts[0].taskBasis = .humanConfirmed
        XCTAssertThrowsError(try ReportValidator.validate(value))
        value.dailyActivity?.prompts[0].scopeReason = "Đối chiếu yêu cầu REP-1: sửa bộ lọc ngày."
        XCTAssertNoThrow(try ReportValidator.validate(value))
        let merged = try ReportReviewActions.merge("a", into: "b", draft: value)
        XCTAssertEqual(merged.dailyActivity?.prompts[0].workItemID, "b")
        XCTAssertEqual(merged.dailyActivity?.prompts[0].scope, .unknown)
        XCTAssertEqual(merged.dailyActivity?.prompts[0].scopeReason, "")
    }
    func testNewSnapshotAndExportsContainActivityButNoRawPromptsAndOldSnapshotStillLoads() throws {
        var value = try report(prompts: [prompt("p", at: day)])
        value.workItems = [ReportWorkItem(id: "w", project: "TW", title: "Kiểm tra báo cáo")]
        value.dailyActivity?.prompts[0].workItemID = "w"
        value.dailyActivity?.prompts[0].taskBasis = .humanConfirmed
        value.dailyActivity?.prompts[0].summary = "Rà soát bộ lọc ngày trong báo cáo."
        value.dailyActivity?.prompts[0].scope = .inScope
        value.dailyActivity?.prompts[0].scopeReason = "Theo yêu cầu REP-1 về báo cáo hằng ngày."
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = ReportSnapshotStore(root: root)
        let saved = try store.save(value, reviewedBy: value.employee.employeeID, now: day)
        XCTAssertEqual(try store.history().first, saved)
        let encoded = try ReportEncoding.encode(value)
        XCTAssertFalse(String(decoding: encoded, as: UTF8.self).contains("PRIVATE_RAW_PROMPT"))
        let pdf = try DailyReportRenderer.pdf(value)
        let pdfText = try XCTUnwrap(PDFDocument(data: pdf)?.string)
        for text in [DailyReportRenderer.plainText(value), DailyReportRenderer.html(value), DailyReportRenderer.markdown(value),
                     DailyReportRenderer.csv(value), String(decoding: try DailyReportRenderer.json(value), as: UTF8.self), pdfText] {
            XCTAssertTrue(text.contains("PiAgent"))
            XCTAssertTrue(text.contains("REP-1"))
            XCTAssertFalse(text.contains("PRIVATE_RAW_PROMPT"))
            XCTAssertFalse(text.contains("sk-abcdefghijklmnop123456"))
        }
        var legacy = value; legacy.dailyActivity = nil
        let old = try store.save(legacy, reviewedBy: value.employee.employeeID, now: day.addingTimeInterval(1))
        XCTAssertFalse(String(decoding: try ReportEncoding.encode(old), as: UTF8.self).contains("dailyActivity"))
        XCTAssertEqual(try store.history().count, 2)
        if let path = ProcessInfo.processInfo.environment["AGENTWATCH_ACTIVITY_PREVIEW_DIR"] {
            let output = URL(fileURLWithPath: path)
            try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
            try pdf.write(to: output.appendingPathComponent("prompt-task-app-report.pdf"))
            try DailyReportRenderer.html(value).write(to: output.appendingPathComponent("prompt-task-app-report.html"), atomically: true, encoding: .utf8)
        }
    }
}
