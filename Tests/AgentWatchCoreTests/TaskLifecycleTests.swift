import XCTest
@testable import AgentWatchCore

final class TaskLifecycleTests: XCTestCase {
    private let start = Date(timeIntervalSince1970: 1_788_825_600)
    private var range: Range<Date> { start..<start.addingTimeInterval(86400) }
    private func usage(_ id: String, session: String, hour: Int) -> UsageEntry {
        UsageEntry(id: id, sessionID: session, agent: "pi", provider: "anthropic", modelID: "claude-sonnet-4-6",
                   timestamp: start.addingTimeInterval(Double(hour * 3600)), tokens: UsageTokens(input: 100, output: 10))
    }
    private func session(_ id: String, entries: [UsageEntry]) -> SessionSummary {
        SessionSummary(id: id, projectDisplay: "/project", source: .piagent, model: "claude-sonnet-4-6", modelFamily: .sonnet,
                       inputTokens: 0, outputTokens: 0, cacheReadTokens: 0, cacheWriteTokens: 0, cost: 0,
                       firstTimestamp: start, lastTimestamp: start.addingTimeInterval(80000), promptCount: 0, toolCallCount: 0,
                       usageEntries: entries)
    }
    private func scan(_ sessions: [SessionSummary]) -> CoachingScanResult {
        CoachingScanResult(prompts: [], sessions: sessions, candidateFileCount: sessions.count, sourceFiles: [], sourceRoots: [])
    }
    private func bind(_ session: String, task: String = "task", run: String = "run", from: Date? = nil, to: Date? = nil) -> TaskSessionBinding {
        TaskSessionBinding(projectPath: "/project", taskID: task, taskRunID: run, source: .piagent,
                           sessionID: session, start: from ?? start, end: to ?? range.upperBound)
    }
    func testEditingLegacyBindingPreservesPriorVersion() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("binding-revision-\(UUID())")
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let initial = TaskSessionBinding(projectPath: "/project", taskID: "old", taskRunID: "run", source: .codex, sessionID: "s", start: Date(timeIntervalSince1970: 0), recordedAt: Date(timeIntervalSince1970: 1))
        try ReportEncoding.encode([initial]).write(to: root.appendingPathComponent("bindings.json"))
        let store = TaskBindingStore(root: root)
        var edited = TaskSessionBinding(projectPath: "/project", taskID: "new", taskRunID: "run", source: .codex, sessionID: "s", start: initial.start, end: Date(timeIntervalSince1970: 100), recordedAt: Date(timeIntervalSince1970: 2))
        edited.id = initial.id
        try store.save(edited)
        XCTAssertEqual(try store.load(), [edited])
        XCTAssertEqual(try store.previousVersions(id: initial.id), [initial])
        try store.save(initial)
        XCTAssertEqual(try store.load(), [initial])
        XCTAssertEqual(try store.previousVersions(id: initial.id), [initial, edited])
    }

    func testMultipleRunsAndSessionsRollUpWithoutDoubleCount() {
        let sessions = [session("s1", entries: [usage("one", session: "s1", hour: 1)]),
                        session("s2", entries: [usage("two", session: "s2", hour: 2)])]
        let result = TaskLifecycleBuilder.build(scan: scan(sessions + [sessions[0]]), journals: [],
            bindings: [bind("s1", run: "r1"), bind("s2", run: "r2")], range: range)
        XCTAssertEqual(result.items.count, 1)
        XCTAssertEqual(result.items.first?.totalTokens, 220)
        XCTAssertEqual(result.items.first?.runIDs, ["r1", "r2"])
        XCTAssertEqual(result.unallocatedTokens, 0)
    }
    func testRequestTimestampDeterminesTaskAndHalfOpenBoundary() {
        let split = start.addingTimeInterval(7200)
        let result = TaskLifecycleBuilder.build(scan: scan([session("s", entries: [usage("a", session: "s", hour: 1), usage("b", session: "s", hour: 2)])]),
            journals: [], bindings: [bind("s", task: "A", to: split), bind("s", task: "B", from: split)], range: range)
        XCTAssertEqual(result.items.count, 2)
        XCTAssertTrue(result.items.allSatisfy { $0.totalTokens == 110 })
    }
    func testUnlinkedAndConflictingBindingRemainUnallocated() {
        let input = scan([session("s", entries: [usage("a", session: "s", hour: 1)])])
        let unknown = TaskLifecycleBuilder.build(scan: input, journals: [], bindings: [], range: range)
        XCTAssertEqual(unknown.unallocatedTokens, 110)
        XCTAssertTrue(unknown.items.isEmpty)
        let conflict = TaskLifecycleBuilder.build(scan: input, journals: [], bindings: [bind("s", task: "A"), bind("s", task: "B")], range: range)
        XCTAssertEqual(conflict.unallocatedTokens, 110)
        XCTAssertTrue(conflict.items.allSatisfy { $0.totalTokens == 0 })
    }
    func testBindingPersistenceRejectsOverlapAndAllowsNextInterval() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("task-bindings-\(UUID())")
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = TaskBindingStore(root: directory)
        let split = start.addingTimeInterval(7200)
        _ = try store.save(bind("s", to: split))
        XCTAssertThrowsError(try store.save(bind("s", task: "other")))
        _ = try store.save(bind("s", task: "next", from: split))
        XCTAssertEqual(try TaskBindingStore(root: directory).load().count, 2)
    }
    func testProjectFilterDoesNotIncludeOtherProjectBindings() {
        let input = scan([session("s", entries: [usage("a", session: "s", hour: 1)])])
        let result = TaskLifecycleBuilder.build(scan: input, journals: [], bindings: [bind("s")], range: range, projectPath: "/other")
        XCTAssertTrue(result.items.isEmpty)
        XCTAssertEqual(result.unallocatedTokens, 0)
    }
}
