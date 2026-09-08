import XCTest
import PDFKit
@testable import AgentWatchCore

final class SimpleDailyActivityTests: XCTestCase, @unchecked Sendable {
    private let date = ISO8601DateFormatter().date(from: "2026-09-08T02:00:00Z")!
    func testStructuredFilesExcludeCommandsOutputAndSourceContents() throws {
        let cases: [(String, Any, [String])] = [
            ("Read", ["file_path": "/repo/a.swift"], ["/repo/a.swift"]),
            ("Edit", ["file_path": "/repo/a.swift", "old_string": "PRIVATE_BODY", "new_string": "PRIVATE_REPLY"], ["/repo/a.swift"]),
            ("functions.apply_patch", "*** Begin Patch\n*** Update File: App/a.swift\n+PRIVATE_BODY\n*** Add File: App/b.swift\n+PRIVATE_REPLY\n*** End Patch", ["App/a.swift", "App/b.swift"]),
            ("functions.read_file", "{\"path\":\"/repo/b.txt\"}", ["/repo/b.txt"]),
            ("Bash", ["command": "cat /repo/a.swift"], []),
            ("functions.exec_command", ["cmd": "echo PRIVATE_COMMAND"], []),
            ("read", ["path": "/repo/c.txt"], ["/repo/c.txt"])]
        for (name, input, paths) in cases {
            let rows = ReportFileActivityReader.extract(name: name, input: input, at: date)
            XCTAssertEqual(rows.map(\.path), paths)
            let encoded = String(data: try ReportEncoding.encode(rows), encoding: .utf8)!
            XCTAssertFalse(encoded.contains("PRIVATE_"))
        }
    }
    func testPDFIncludesOnlyEmployeeRequestsAppsAndFileTargets() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let url = root.appendingPathComponent("session.jsonl")
        let records: [[String: Any]] = [
            ["type": "assistant", "timestamp": "2026-09-08T02:00:01Z", "message": ["role":"assistant", "content": [
                ["type":"text", "text":"PRIVATE_MODEL_RESPONSE"],
                ["type":"tool_use", "id":"r", "name":"Read", "input":["file_path":"/demo/Report.swift"]],
                ["type":"tool_use", "id":"b", "name":"Bash", "input":["command":"PRIVATE_COMMAND"]]]]],
            ["type": "assistant", "timestamp": "2026-09-08T02:00:03Z", "message": ["role":"assistant", "content": [
                ["type":"tool_use", "id":"w", "name":"Write", "input":["file_path":"/demo/result.pdf", "content":"PRIVATE_FILE_BODY"]]]]],
            ["type":"user", "timestamp":"2026-09-08T02:00:04Z", "message":["content":[["type":"tool_result", "tool_use_id":"w", "content":"PRIVATE_TOOL_OUTPUT"]]]]]
        var bytes = Data()
        for row in records { bytes.append(try JSONSerialization.data(withJSONObject: row)); bytes.append(10) }
        try bytes.write(to: url)
        let session = SessionSummary(id: "s", projectDisplay: "/demo", source: .cli, model: "unknown", modelFamily: .unknown,
            inputTokens: 0, outputTokens: 0, cacheReadTokens: 0, cacheWriteTokens: 0, cost: 0,
            firstTimestamp: date, lastTimestamp: date.addingTimeInterval(4), promptCount: 2, toolCallCount: 3, fileURL: url, usageEntries: [])
        let prompts = ["Xuất báo cáo PDF tối giản cho anh.", "<codex_internal_context><objective>PRIVATE_AUTO_CONTINUATION</objective></codex_internal_context>"].enumerated().map { index, text in
            PromptRecord(id: "p\(index)", timestamp: date.addingTimeInterval(Double(index * 2)), projectSlug: "demo", projectDisplay: "/demo", sessionUuid: "s", text: text, score: PromptScorer.score(text), source: .cli)
        }
        let period = try DailyReportPeriod(day: date, timeZone: "Asia/Ho_Chi_Minh", cutoff: date.addingTimeInterval(10))
        let scan = CoachingScanResult(prompts: prompts, sessions: [session], candidateFileCount: 1, sourceFiles: [], sourceRoots: [])
        let desktop = DesktopActivityReport(collectionStartedAt: date, observedSeconds: 10, apps: [DesktopAppSummary(id: "codex", name: "Codex", seconds: 10)])
        let report = AutomaticDailyReport.build(employee: EmployeeProfile(organizationID: "demo", employeeID: "e", displayName: "Người dùng mẫu"), period: period, scan: scan, desktop: desktop)
        XCTAssertEqual(report.dailyActivity?.prompts.first?.fileActivities?.map(\.path), ["/demo/Report.swift", "/demo/result.pdf"])
        XCTAssertTrue(report.evidence.allSatisfy { $0.kind != .toolResult })
        let pdf = try DailyReportRenderer.pdf(report)
        let text = try XCTUnwrap(PDFDocument(data: pdf)?.string)
        for wanted in ["1 prompt đã gửi", "Xuất báo cáo PDF tối giản", "Report.swift", "result.pdf", "Codex"] { XCTAssertTrue(text.contains(wanted), wanted) }
        for excluded in ["PRIVATE_", "Usage & quota", "Kết quả:", "Vướng mắc:", "GHI NHẬN CÔNG CỤ"] { XCTAssertFalse(text.contains(excluded), excluded) }
        XCTAssertNoThrow(try ReportSnapshotStore(root: root.appendingPathComponent("snapshots")).save(report, reviewedBy: "e", now: date.addingTimeInterval(10)))
        if let output = ProcessInfo.processInfo.environment["AGENTWATCH_SIMPLE_PREVIEW"] { try pdf.write(to: URL(fileURLWithPath: output)) }
        // A same-length source rewrite must invalidate file metadata cached above.
        try String(data: bytes, encoding: .utf8)!.replacingOccurrences(of: "Report.swift", with: "Review.swift").write(to: url, atomically: true, encoding: .utf8)
        XCTAssertEqual(ReportFileActivityReader.read(session: session, period: period).first?.path, "/demo/Review.swift")
    }

    func testDailyQueryPersistsRestoresAndSeparatesDayAndIdentity() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let roots = AgentLogRoots(home: root.path, environment: [:])
        let scans = CoachingQueryStore(url: root.appendingPathComponent("query.sqlite"))
        let desktop = DesktopAppActivityStore(root: root.appendingPathComponent("desktop"))
        let cache = root.appendingPathComponent("daily")
        let query = DailyActivityQuery(roots: roots, scans: scans, desktop: desktop, cacheDirectory: cache)
        let profile = EmployeeProfile(organizationID: "demo", employeeID: "e", displayName: "Mẫu")
        let missing = try await query.cached(profile: profile, day: date, now: date)
        XCTAssertNil(missing)
        async let first = query.refresh(profile: profile, day: date, now: date)
        async let second = query.refresh(profile: profile, day: date, now: date)
        let reports = try await (first, second)
        XCTAssertEqual(reports.0.period, reports.1.period)
        let restored = DailyActivityQuery(roots: roots, scans: scans, desktop: desktop, cacheDirectory: cache)
        let cached = try await restored.cached(profile: profile, day: date, now: date)
        XCTAssertEqual(cached?.period, reports.0.period)
        var other = profile; other.employeeID = "other"
        let wrongIdentity = try await restored.cached(profile: other, day: date, now: date)
        let wrongDay = try await restored.cached(profile: profile, day: date.addingTimeInterval(-86400), now: date)
        XCTAssertNil(wrongIdentity); XCTAssertNil(wrongDay)
    }
}
