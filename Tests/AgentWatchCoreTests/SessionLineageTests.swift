import XCTest
@testable import AgentWatchCore

final class SessionLineageTests: XCTestCase {
    private func parse(_ text: String, source: SessionSource = .codex) -> SessionLineageSnapshot {
        SessionLineageReader.extract(data: Data(text.utf8), sessionRef: source.rawValue + "|child", sessionID: "child", source: source,
            file: URL(fileURLWithPath: "/synthetic/child.jsonl"), before: .distantFuture)
    }
    func testForkUsesMatchingHeaderAndDoesNotReadParent() {
        let result = parse("{\"type\":\"session_meta\",\"timestamp\":\"2026-09-08T00:00:00Z\",\"payload\":{\"id\":\"child\",\"forked_from_id\":\"parent\"}}\n")
        XCTAssertEqual(result.relations.map(\.kind), [.fork])
        XCTAssertEqual(result.relations.first?.relatedRef, "parent")
        XCTAssertEqual(result.relations.first?.localRef, "/synthetic/child.jsonl#line=1")
        let pi = parse("{\"type\":\"session\",\"id\":\"child\",\"timestamp\":\"2026-09-08T00:00:00Z\",\"parentSession\":\"/must-not-open/parent.jsonl\"}\n", source: .piagent)
        XCTAssertEqual(pi.relations.first?.relatedRef, "/must-not-open/parent.jsonl")
    }
    func testMismatchedHeaderAndIncompleteTailExcluded() {
        let wrong = parse("{\"type\":\"session_meta\",\"timestamp\":\"2026-09-08T00:00:00Z\",\"payload\":{\"id\":\"other\",\"forked_from_id\":\"parent\"}}\n")
        XCTAssertTrue(wrong.relations.isEmpty)
        XCTAssertFalse(wrong.warnings.isEmpty)
        let tail = parse("{\"type\":\"session_meta\",\"timestamp\":\"2026-09-08T00:00:00Z\",\"payload\":{\"id\":\"child\",\"forked_from_id\":\"parent\"}}")
        XCTAssertTrue(tail.relations.isEmpty)
        XCTAssertFalse(tail.warnings.isEmpty)
    }
    func testSpawnAndResumeAreRequestsAndNeverProofOfCompletion() {
        let text = """
        {"type":"response_item","timestamp":"2026-09-08T00:00:00Z","payload":{"type":"function_call","name":"spawn_agent","call_id":"a","arguments":"{}"}}
        {"type":"response_item","timestamp":"2026-09-08T00:00:01Z","payload":{"type":"function_call","name":"resume_agent","call_id":"b","arguments":"{\\"id\\":\\"child-2\\"}"}}

        """
        let result = parse(text)
        XCTAssertEqual(result.relations.map(\.kind), [.subagentRequested, .resumeRequested])
        XCTAssertNil(result.relations[0].relatedRef)
        XCTAssertEqual(result.relations[1].relatedRef, "child-2")
    }
    func testClaudeResumeAndMalformedRows() {
        let text = """
        broken
        {"type":"assistant","timestamp":"2026-09-08T00:00:00Z","message":{"content":[{"type":"tool_use","id":"a","name":"Agent","input":{"resume":"agent-id"}}]}}

        """
        let result = parse(text, source: .cli)
        XCTAssertEqual(result.relations.map(\.kind), [.resumeRequested])
        XCTAssertEqual(result.relations.first?.relatedRef, "agent-id")
        XCTAssertFalse(result.warnings.isEmpty)
    }
}
