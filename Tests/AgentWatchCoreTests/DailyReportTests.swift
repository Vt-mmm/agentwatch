import XCTest
import PDFKit
@testable import AgentWatchCore

final class DailyReportTests: XCTestCase {
    private let day = ISO8601DateFormatter().date(from: "2026-09-06T08:00:00Z")!
    private func draft() throws -> DailyReportDraft {
        let period = try DailyReportPeriod(day: day, timeZone: "Asia/Ho_Chi_Minh", cutoff: day)
        let profile = EmployeeProfile(organizationID: "Công ty mẫu", employeeID: "NV-001", displayName: "Nguyễn Minh An")
        let evidence = ReportEvidence(id: "e1", sessionRef: "claude|s1", kind: .humanConfirmation, observedAt: day,
                                      summary: "Nhân viên xác nhận đã kiểm tra thay đổi.", localRef: "/Users/private/project/session.jsonl",
                                      digest: "synthetic-only")
        let item = ReportWorkItem(id: "w1", project: "Cổng báo cáo", title: "Sửa bộ lọc ngày và dữ liệu report",
                                  sessionRefs: ["claude|s1"], status: .readyForReview,
                                  activities: ["Rà soát cách phân bổ sự kiện sát nửa đêm theo múi giờ công ty.", "Bổ sung kiểm tra cho bản log lặp và chi phí chưa rõ."],
                                  claims: [WorkClaim(text: "Đã sửa bộ lọc và kiểm tra các tình huống biên; thay đổi đang chờ đồng nghiệp review.", basis: .humanConfirmed, evidenceIDs: ["e1"])],
                                  evidenceIDs: ["e1"], blockers: "Chờ người phụ trách xác nhận định dạng đầu ra.",
                                  nextActions: "Tiếp nhận góp ý và hoàn thiện mẫu báo cáo gửi quản lý.", humanConfirmed: true)
        let entry = UsageEntry(id: "request1", sessionID: "s1", agent: "claude", provider: "anthropic", modelID: "claude-sonnet-4-6", timestamp: day,
                               tokens: UsageTokens(input: 1000, output: 200, cacheRead: 300))
        return DailyReportDraft(employee: profile, period: period, workItems: [item], evidence: [evidence],
                                usage: [ReportUsageRecord(entry: entry)], quota: [], warnings: ["Dữ liệu giả lập để kiểm tra bố cục. Không có quota lịch sử cho ngày này."],
                                sourceFiles: [], sourceRoots: [], summary: "Tập trung cải thiện độ chính xác của báo cáo ngày và chuẩn bị định dạng để quản lý dễ theo dõi.",
                                notes: "Bản mẫu hoàn toàn giả lập. Công việc ngoài coding agent do nhân viên tự bổ sung.", narrativeProvenance: "deterministic-template-v1")
    }
    private func temporaryRoot() throws -> URL {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        return root
    }
    func testCompletionRequiresConfirmationAndResultEvidence() throws {
        var report = try draft(); report.workItems[0].status = .completed; report.workItems[0].humanConfirmed = false
        XCTAssertThrowsError(try ReportValidator.validate(report))
        report.workItems[0].humanConfirmed = true; report.workItems[0].claims = []
        XCTAssertThrowsError(try ReportValidator.validate(report))
        report.workItems[0].claims = [WorkClaim(text: "Hoàn thành", basis: .humanConfirmed, evidenceIDs: ["missing"])]
        XCTAssertThrowsError(try ReportValidator.validate(report))
    }
    func testSnapshotsAreRevisionedAndTamperedHistoryFailsReadback() throws {
        let root = try temporaryRoot(), store = ReportSnapshotStore(root: root)
        var report = try draft()
        let one = try store.save(report, reviewedBy: "NV-001", now: day)
        report.notes = "Điều chỉnh sau review"
        let two = try store.save(report, reviewedBy: "NV-001", now: day.addingTimeInterval(2))
        XCTAssertEqual(one.revision, 1); XCTAssertEqual(two.revision, 2)
        XCTAssertNotEqual(one.contentHash, two.contentHash)
        XCTAssertEqual(try store.history().count, 2)
        let url = root.appendingPathComponent(one.id + ".json")
        let text = try String(contentsOf: url, encoding: .utf8)
        XCTAssertTrue(text.contains("2026-09-06T"))
        try text.replacingOccurrences(of: "Cổng báo cáo", with: "Nội dung bị thay").write(to: url, atomically: true, encoding: .utf8)
        XCTAssertThrowsError(try store.history())
    }
    func testManagerExportsExcludeLocalPathsAndRawSecretsAndEscapeHTMLCSV() throws {
        var report = try draft()
        report.notes = "<script>alert(1)</script> /Users/private/secret sk-abcdefghijklmnop123456"
        report.workItems[0].title = "=HYPERLINK(\"https://example.org\")"
        let html = DailyReportRenderer.html(report)
        XCTAssertFalse(html.contains("<script>")); XCTAssertTrue(html.contains("&lt;script&gt;"))
        let json = String(data: try DailyReportRenderer.json(report), encoding: .utf8)!
        for text in [html, json, DailyReportRenderer.markdown(report), DailyReportRenderer.csv(report)] {
            XCTAssertFalse(text.contains("/Users/private")); XCTAssertFalse(text.contains("sk-abcdefghijklmnop123456")); XCTAssertFalse(text.contains("localRef"))
        }
        XCTAssertTrue(DailyReportRenderer.csv(report).contains("'=HYPERLINK"))
    }
    func testModelCannotEditMetricsOrApproveCompletedWork() throws {
        let report = try draft()
        XCTAssertThrowsError(try ReportNarrative.apply(Data("{\"summary\":\"x\",\"items\":[],\"tokens\":0}".utf8), to: report))
        let missing = Data("{\"summary\":\"x\",\"items\":[{\"workItemID\":\"w1\",\"text\":\"done\",\"evidenceIDs\":[\"missing\"]}]}".utf8)
        XCTAssertThrowsError(try ReportNarrative.apply(missing, to: report))
        let valid = Data("{\"summary\":\"Gợi ý\",\"items\":[{\"workItemID\":\"w1\",\"text\":\"Có thay đổi cần review\",\"evidenceIDs\":[\"e1\"]}]}".utf8)
        let next = try ReportNarrative.apply(valid, to: report)
        XCTAssertEqual(next.totalTokens, report.totalTokens)
        XCTAssertEqual(next.period, report.period)
        XCTAssertEqual(next.workItems[0].status, .unknown)
        XCTAssertFalse(next.workItems[0].humanConfirmed)
        XCTAssertEqual(report.workItems[0].status, .readyForReview)
    }
    func testHistoricalReportRejectsTodaysQuotaAndWrongEmployee() throws {
        var report = try draft()
        report.quota = [QuotaParser.pi(at: day.addingTimeInterval(86400))]
        XCTAssertThrowsError(try ReportValidator.validate(report))
        let store = ReportSnapshotStore(root: try temporaryRoot())
        XCTAssertThrowsError(try store.save(try draft(), reviewedBy: "another-employee"))
    }
    func testClosedSnapshotSchemaRejectsAdditionalNestedFields() throws {
        let store = ReportSnapshotStore(root: try temporaryRoot())
        let snapshot = try store.save(try draft(), reviewedBy: "NV-001", now: day)
        let bytes = try ReportEncoding.encode(snapshot)
        try ReportSchema.validateSnapshot(bytes)
        var object = try JSONSerialization.jsonObject(with: bytes) as! [String: Any]
        var report = object["report"] as! [String: Any]
        var employee = report["employee"] as! [String: Any]
        employee["sendTo"] = "not-authorized@example.org"; report["employee"] = employee; object["report"] = report
        XCTAssertThrowsError(try ReportSchema.validateSnapshot(JSONSerialization.data(withJSONObject: object)))
    }
    func testBackfilledHumanNoteKeepsActualEntryTime() throws {
        var report = try draft()
        report.evidence.append(ReportEvidence(id: "backfill", sessionRef: nil, kind: .humanConfirmation,
                                              observedAt: day.addingTimeInterval(86400), summary: "Nhập bổ sung hôm sau",
                                              digest: "synthetic", appliesToDay: report.period.start))
        XCTAssertNoThrow(try ReportValidator.validate(report))
        XCTAssertGreaterThan(report.evidence.last!.observedAt, report.period.end)
    }
    func testManualMergePreservesAccountingAndInvalidatesCompletionConfirmation() throws {
        var report = try draft()
        report.workItems.append(ReportWorkItem(id: "w2", project: "Cổng báo cáo", title: "Kiểm tra bổ sung", sessionRefs: ["codex|s2"],
                                              status: .inProgress, evidenceIDs: ["e1"]))
        let result = try ReportReviewActions.merge("w2", into: "w1", draft: report)
        XCTAssertEqual(result.workItems.count, 1)
        XCTAssertEqual(result.workItems[0].sessionRefs.count, 2)
        XCTAssertEqual(result.totalTokens, report.totalTokens)
        XCTAssertEqual(result.knownCostSubtotal, report.knownCostSubtotal)
        XCTAssertFalse(result.workItems[0].humanConfirmed)
        XCTAssertEqual(result.workItems[0].status, .unknown)
    }
    func testPiJournalValidatesExactWriterHashChainAndRejectsTampering() throws {
        let root = try temporaryRoot()
        let file = root.appendingPathComponent(".pi/piagent-state/task-journal/events.jsonl")
        try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        let original = #"{"schemaVersion":1,"sequence":1,"eventType":"session-bound","taskRunId":"run1","taskId":"REP-1","sessionId":"pi1","sessionName":"REP-1 Filter","data":{},"recordedAt":"2026-09-06T07:00:00.000Z"}"#
        let hash = ReportEncoding.digest(Data(original.utf8))
        let line = String(original.dropLast()) + ",\"hash\":\"" + hash + "\"}\n"
        try line.write(to: file, atomically: true, encoding: .utf8)
        let result = PiTaskJournal.read(project: root, period: try draft().period)
        XCTAssertEqual(result.links.count, 1)
        XCTAssertEqual(result.links.first?.taskID, "REP-1")
        try line.replacingOccurrences(of: "REP-1", with: "REP-2").write(to: file, atomically: true, encoding: .utf8)
        let tampered = PiTaskJournal.read(project: root, period: try draft().period)
        XCTAssertTrue(tampered.links.isEmpty)
        XCTAssertFalse(tampered.warnings.isEmpty)
    }
    func testTaskJournalPartitionsSessionUsageAndConservesTotals() throws {
        let root = try temporaryRoot()
        let source = root.appendingPathComponent("journal.jsonl")
        try Data().write(to: source)
        let period = try draft().period
        let links = [
            JournalTaskLink(projectPath: root.path, taskID: "REP-1", taskRunID: "r1", sessionID: "pi", sessionName: "Bộ lọc", recordedAt: day.addingTimeInterval(-300), evidenceID: "j1"),
            JournalTaskLink(projectPath: root.path, taskID: "REP-2", taskRunID: "r2", sessionID: "pi", sessionName: "Định dạng", recordedAt: day.addingTimeInterval(-100), evidenceID: "j2")]
        let journal = PiTaskJournalResult(links: links, evidence: [], warnings: [], manifest: SourceFileManifest.inspect(source))
        let entries = [-400.0, -200.0, -50.0].enumerated().map { index, offset in
            UsageEntry(id: "request-\(index)", sessionID: "pi", agent: "pi", provider: "openai", modelID: "gpt-5.6-sol", timestamp: day.addingTimeInterval(offset), tokens: UsageTokens(input: 10, output: 2))
        }
        let session = SessionSummary(id: "pi", projectDisplay: root.path, source: .piagent, model: "gpt-5.6-sol", modelFamily: .gpt,
                                     inputTokens: 30, outputTokens: 6, cacheReadTokens: 0, cacheWriteTokens: 0, cost: 0,
                                     firstTimestamp: day.addingTimeInterval(-400), lastTimestamp: day, promptCount: 1, toolCallCount: 0, usageEntries: entries)
        let scan = CoachingScanResult(prompts: [], sessions: [session], candidateFileCount: 1, sourceFiles: [], sourceRoots: [])
        let report = DailyReportBuilder.build(employee: try draft().employee, period: period, scan: scan, journals: [journal])
        XCTAssertEqual(report.workItems.count, 2)
        XCTAssertEqual(report.totalTokens, 36)
        XCTAssertEqual(report.unallocatedTokens, 12)
        XCTAssertNotEqual(report.usage[1].workItemID, report.usage[2].workItemID)
        XCTAssertEqual(report.usage.filter { $0.workItemID != nil }.reduce(0) { $0 + $1.tokens.total } + report.unallocatedTokens, report.totalTokens)
        XCTAssertNoThrow(try ReportValidator.validate(report))
    }
    func testDraftPersistsUnsavedNotes() throws {
        let store = DailyReportDraftStore(root: try temporaryRoot())
        var value = try draft(); value.notes = "Ghi chú chưa chốt"
        try store.save(value)
        XCTAssertEqual(try store.load()?.notes, value.notes)
    }
    func testPDFIsPaginatedSelectableAndVietnameseTextSurvives() throws {
        var report = try draft()
        for index in 2...12 {
            var item = report.workItems[0]
            item.title = "Công việc số \(index): rà soát luồng báo cáo tiếng Việt"
            report.workItems.append(ReportWorkItem(id: "w\(index)", project: item.project, title: item.title,
                                                 status: .inProgress, activities: item.activities, evidenceIDs: ["e1"], nextActions: item.nextActions))
        }
        let bytes = try DailyReportRenderer.pdf(report, revision: 1)
        let document = try XCTUnwrap(PDFDocument(data: bytes))
        XCTAssertGreaterThan(document.pageCount, 1)
        XCTAssertTrue(document.string?.contains("Nguyễn Minh An") == true)
        XCTAssertTrue(document.string?.contains("Công việc số 12") == true)
        if let output = ProcessInfo.processInfo.environment["AGENTWATCH_REPORT_PREVIEW_DIR"] {
            let root = URL(fileURLWithPath: output)
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
            let sample = try draft()
            try DailyReportRenderer.pdf(sample, revision: 1).write(to: root.appendingPathComponent("daily-report-sample.pdf"))
            try DailyReportRenderer.html(sample, revision: 1).write(to: root.appendingPathComponent("daily-report-sample.html"), atomically: true, encoding: .utf8)
            try bytes.write(to: root.appendingPathComponent("daily-report-pagination.pdf"))
        }
    }
    func testUnlinkedSessionsRemainSuggestionsAndUsageStaysUnallocated() throws {
        let profile = try draft().employee, period = try draft().period
        let entry = UsageEntry(id: "pi-request", sessionID: "pi-session", agent: "pi", provider: "openai", modelID: "gpt-5.6-sol", timestamp: day, tokens: UsageTokens(input: 100, output: 20))
        let session = SessionSummary(id: "pi-session", sessionTitle: "Already done", projectDisplay: "/project", source: .piagent, model: entry.modelID, modelFamily: .gpt,
                                     inputTokens: 100, outputTokens: 20, cacheReadTokens: 0, cacheWriteTokens: 0, cost: 0,
                                     firstTimestamp: day, lastTimestamp: day, promptCount: 1, toolCallCount: 0, usageEntries: [entry])
        let scan = CoachingScanResult(prompts: [], sessions: [session], candidateFileCount: 1, sourceFiles: [], sourceRoots: [])
        let result = DailyReportBuilder.build(employee: profile, period: period, scan: scan)
        XCTAssertEqual(result.workItems[0].status, .unknown)
        XCTAssertEqual(result.unallocatedTokens, 120)
        XCTAssertEqual(result.workItems[0].title, "Already done")
        XCTAssertTrue(result.workItems[0].claims.isEmpty)
    }
    func testMalformedUsageStillAllowsAnExplicitlyPartialDailyReport() throws {
        let base = try draft()
        let invalid = UsageEntry(id: "bad", sessionID: "pi-session", agent: "pi", provider: "openai", modelID: "unknown", timestamp: day,
                                 tokens: UsageTokens(input: -1, output: 2))
        let valid = UsageEntry(id: "good", sessionID: "pi-session", agent: "pi", provider: "openai", modelID: "unknown", timestamp: day,
                               tokens: UsageTokens(input: 10, output: 2))
        let session = SessionSummary(id: "pi-session", sessionTitle: "Observed work", projectDisplay: "/project", source: .piagent, model: "unknown", modelFamily: .unknown,
                                     inputTokens: 0, outputTokens: 0, cacheReadTokens: 0, cacheWriteTokens: 0, cost: 0,
                                     firstTimestamp: day, lastTimestamp: day, promptCount: 1, toolCallCount: 0, usageEntries: [invalid, valid])
        let scan = CoachingScanResult(prompts: [], sessions: [session], candidateFileCount: 1, sourceFiles: [], sourceRoots: [])
        let result = DailyReportBuilder.build(employee: base.employee, period: base.period, scan: scan)
        XCTAssertEqual(result.totalTokens, 12); XCTAssertEqual(result.usage.count, 1)
        XCTAssertTrue(result.warnings.contains { $0.contains("bad") })
        _ = try ReportSnapshotStore(root: temporaryRoot()).save(result, reviewedBy: base.employee.employeeID)
        var directInvalid = result; directInvalid.usage.append(ReportUsageRecord(entry: invalid))
        XCTAssertThrowsError(try ReportValidator.validate(directInvalid))
    }
}
