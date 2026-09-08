import XCTest
@testable import AgentWatchCore

final class TaskOutcomeTests: XCTestCase {
    let file = URL(fileURLWithPath: "/tmp/synthetic.jsonl")
    let range = Date.distantPast..<Date.distantFuture
    func tool(_ command: String, completed: Bool = true, output: String = "All tests passed") -> SessionEvent {
        SessionEvent(id: "t", timestamp: "2026-09-08T00:00:00Z", kind: .toolUse, toolName: "Bash", summary: command,
            completed: completed, completedAt: completed ? "2026-09-08T00:00:01Z" : nil, resultPreview: output)
    }
    func testAgentStatementAndSuccessfulToolNeverBecomeAcceptance() {
        let events = [SessionEvent(id: "a", timestamp: "2026-09-08T00:00:00Z", kind: .assistantText, summary: "Done, tests pass"), tool("swift test")]
        let evidence = TaskOutcomeReader.extract(events: events, sessionRef: "s", file: file, range: range)
        XCTAssertEqual(evidence.map(\.kind), [.agentStatement, .testInvocation, .testOutput])
        XCTAssertFalse(evidence.contains { $0.kind == .humanAcceptance })
        XCTAssertTrue(evidence.allSatisfy { $0.localRef.contains("#event=") })
    }
    func testEchoAndShellCompositionDoNotCountAsTestInvocation() {
        for command in ["echo 'All tests passed'", "echo swift test", "swift test; echo pass", "swift test | cat", "npm test && echo pass"] {
            let evidence = TaskOutcomeReader.extract(events: [tool(command)], sessionRef: "s", file: file, range: range)
            XCTAssertEqual(evidence.map(\.kind), [.toolResponse])
        }
    }
    func testUnfinishedToolHasInvocationWithoutResultAndThinkingExcluded() {
        let thinking = SessionEvent(id: "thinking", timestamp: "2026-09-08T00:00:00Z", kind: .assistantThinking, summary: "private")
        let evidence = TaskOutcomeReader.extract(events: [tool("pytest", completed: false), thinking], sessionRef: "s", file: file, range: range)
        XCTAssertEqual(evidence.map(\.kind), [.testInvocation])
    }
    func testResultUsesCompletionTimeAndMissingTimeIsNotInvented() {
        let end = ISO8601DateFormatter().date(from: "2026-09-08T00:00:01Z")!
        let evidence = TaskOutcomeReader.extract(events: [tool("cargo test")], sessionRef: "s", file: file, range: Date.distantPast..<end)
        XCTAssertEqual(evidence.map(\.kind), [.testInvocation])
        var incomplete = tool("pytest"); incomplete.completedAt = nil
        XCTAssertEqual(TaskOutcomeReader.extract(events: [incomplete], sessionRef: "s", file: file, range: range).map(\.kind), [.testInvocation])
    }
    func testTaskSwitchUsesInvocationTimeAndAmbiguityIsExcluded() throws {
        let start = ISO8601DateFormatter().date(from: "2026-09-08T00:00:00Z")!
        let item = TaskLifecycleItem(id: "item", projectPath: "/project", taskID: "first", runIDs: ["r1"], sessionRefs: ["cli|s"], modelIDs: [], timeline: [], ledgerEntries: [], warnings: [])
        let first = TaskSessionBinding(projectPath: "/project", taskID: "first", taskRunID: "r1", source: .cli, sessionID: "s", start: start, end: start.addingTimeInterval(0.5))
        let second = TaskSessionBinding(projectPath: "/project", taskID: "second", taskRunID: "r2", source: .cli, sessionID: "s", start: start.addingTimeInterval(0.5))
        let rows = TaskOutcomeReader.extract(events: [tool("swift test")], sessionRef: "cli|s", file: file, range: range)
        XCTAssertEqual(rows.count, 2)
        for row in rows {
            XCTAssertTrue(TaskOutcomeReader.belongs(row, source: .cli, sessionID: "s", item: item, bindings: [first, second], links: []))
            XCTAssertFalse(TaskOutcomeReader.belongs(row, source: .cli, sessionID: "s", item: item, bindings: [], links: []))
        }
        let conflict = TaskSessionBinding(projectPath: "/project", taskID: "other", taskRunID: "r3", source: .cli, sessionID: "s", start: start)
        XCTAssertFalse(TaskOutcomeReader.belongs(rows[0], source: .cli, sessionID: "s", item: item, bindings: [first, conflict], links: []))
    }

    func testAcceptancePersistsExactRunsAndProjectIsolation() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("acceptance-\(UUID())")
        defer { try? FileManager.default.removeItem(at: root) }
        let store = TaskAcceptanceStore(root: root)
        let acceptance = TaskAcceptance(projectPath: "/project/a", taskID: "task", runIDs: ["r1"], evidence: TaskOutcomeReader.extract(events: [tool("swift test")], sessionRef: "s", file: file, range: range), reviewer: "Operator", note: "Checked expected output")
        try store.append(acceptance)
        XCTAssertThrowsError(try store.append(acceptance))
        XCTAssertEqual(try store.load(projectPath: "/project/a", taskID: "task").first?.runIDs, ["r1"])
        XCTAssertTrue(try store.load(projectPath: "/project/b", taskID: "task").isEmpty)
        XCTAssertThrowsError(try store.append(TaskAcceptance(projectPath: "/project/a", taskID: "task", runIDs: ["r1"], evidence: [], reviewer: "Operator", note: "Done")))
    }
}
