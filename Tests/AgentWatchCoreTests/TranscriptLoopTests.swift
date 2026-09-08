import XCTest
@testable import AgentWatchCore

final class TranscriptLoopTests: XCTestCase {
    func event(_ id: String, _ second: Int, digest: String? = "same", error: Bool? = nil) -> SessionEvent {
        SessionEvent(id: id, timestamp: "2026-09-08T00:00:\(String(format: "%02d", second))Z", kind: .toolUse, toolName: "bash", toolUseId: id,
            summary: "command", completed: true, completedAt: "2026-09-08T00:00:\(String(format: "%02d", second + 1))Z",
            resultPreview: "same preview", inputDigest: "input", outputDigest: digest, toolIsError: error)
    }
    func analyze(_ events: [SessionEvent], eligible: Set<String>? = nil) -> [TaskOutcomeEvidence] {
        TranscriptLoopAnalyzer.analyze(events: events, eligibleIDs: eligible ?? Set(events.map(\.id)), sessionRef: "s",
            file: URL(fileURLWithPath: "/synthetic"), range: Date.distantPast..<Date.distantFuture)
    }
    func testDistinctSequentialCallsWithUnknownErrorAreNotLabelledErrors() {
        let result = analyze([event("a", 0), event("b", 2), event("c", 4)])
        XCTAssertEqual(result.count, 1)
        XCTAssertEqual(result.first?.kind, .repeatedToolSequence)
        XCTAssertTrue(result.first?.summary.contains("chưa có cờ lỗi") == true)
        XCTAssertTrue(result.first?.summary.contains("#event=c") == true)
    }
    func testSamePreviewDifferentOutputMissingHashDuplicateIDAndConcurrencyDoNotProveLoop() {
        XCTAssertTrue(analyze([event("a", 0), event("b", 2, digest: "different"), event("c", 4)]).isEmpty)
        XCTAssertTrue(analyze([event("a", 0), event("b", 2, digest: nil), event("c", 4)]).isEmpty)
        XCTAssertTrue(analyze([event("a", 0), event("a", 2), event("c", 4)]).isEmpty)
        XCTAssertTrue(analyze([event("a", 0), event("b", 0), event("c", 0)]).isEmpty)
    }
    func testTaskGapAndNewUserMessageBreakChain() {
        let events = [event("a", 0), event("b", 2), event("c", 4), event("d", 6)]
        XCTAssertTrue(analyze(events, eligible: ["a", "c", "d"]).isEmpty)
        let user = SessionEvent(id: "u", timestamp: "2026-09-08T00:00:03Z", kind: .userMessage, summary: "new instruction")
        XCTAssertTrue(analyze([events[0], events[1], user, events[2]]).isEmpty)
    }
    func testAllThreeParsersRetainFullDigestsAndLatestResult() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("tool-digest-\(UUID())")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        func write(_ name: String, _ rows: [[String: Any]]) throws -> URL {
            let url = root.appendingPathComponent(name + ".jsonl")
            var data = Data()
            for row in rows { data.append(try JSONSerialization.data(withJSONObject: row, options: .sortedKeys)); data.append(10) }
            try data.write(to: url); return url
        }
        let input: [String: Any] = ["command": "synthetic"]
        let cli = try write("claude", [
            ["type": "assistant", "timestamp": "2026-09-08T00:00:00Z", "message": ["content": [["type": "tool_use", "id": "a", "name": "Bash", "input": input]]]],
            ["type": "user", "timestamp": "2026-09-08T00:00:01Z", "message": ["content": [["type": "tool_result", "tool_use_id": "a", "content": "old", "is_error": true]]]],
            ["type": "user", "timestamp": "2026-09-08T00:00:02Z", "message": ["content": [["type": "tool_result", "tool_use_id": "a", "content": "new", "is_error": false]]]]])
        let codex = try write("codex", [
            ["type": "response_item", "timestamp": "2026-09-08T00:00:00Z", "payload": ["type": "function_call", "call_id": "a", "name": "bash", "arguments": "{\"command\":\"synthetic\"}"]],
            ["type": "response_item", "timestamp": "2026-09-08T00:00:01Z", "payload": ["type": "function_call_output", "call_id": "a", "output": "old"]],
            ["type": "response_item", "timestamp": "2026-09-08T00:00:02Z", "payload": ["type": "function_call_output", "call_id": "a", "output": "new"]]])
        let pi = try write("pi", [
            ["type": "message", "timestamp": "2026-09-08T00:00:00Z", "message": ["role": "assistant", "content": [["type": "toolCall", "id": "a", "name": "bash", "arguments": input]]]],
            ["type": "message", "timestamp": "2026-09-08T00:00:01Z", "message": ["role": "toolResult", "toolCallId": "a", "content": "old", "isError": true]],
            ["type": "message", "timestamp": "2026-09-08T00:00:02Z", "message": ["role": "toolResult", "toolCallId": "a", "content": "new", "isError": false]]])
        let results = [JsonlParser.parseSession(at: cli, eventLimit: nil), CodexJsonlParser.parseSession(at: codex, eventLimit: nil), PiAgentJsonlParser.parseSession(at: pi, eventLimit: nil)]
        for (index, stats) in results.enumerated() {
            let event = try XCTUnwrap(stats.events.first { $0.kind == .toolUse })
            XCTAssertEqual(event.inputDigest, ToolEvidenceDigest.hash(input))
            XCTAssertEqual(event.outputDigest, ToolEvidenceDigest.hash("new"))
            XCTAssertEqual(event.completedAt, "2026-09-08T00:00:02Z")
            if index == 1 { XCTAssertNil(event.toolIsError) } else { XCTAssertEqual(event.toolIsError, false) }
        }
    }

    func testAmbiguousDuplicateCallRetractsEarlierCandidateAndResultRevisionsStayConservative() {
        XCTAssertTrue(analyze([event("a", 0), event("b", 2), event("c", 4), event("d", 6, digest: "changed"), event("a", 8)]).isEmpty)
        var value = event("a", 0)
        XCTAssertTrue(ToolEvidenceDigest.update(&value, output: "latest", error: true, timestamp: "2026-09-08T00:00:05Z"))
        XCTAssertFalse(ToolEvidenceDigest.update(&value, output: "old", error: false, timestamp: "2026-09-08T00:00:02Z"))
        XCTAssertEqual(value.outputDigest, ToolEvidenceDigest.hash("latest"))
        XCTAssertTrue(ToolEvidenceDigest.update(&value, output: "conflict", error: false, timestamp: "2026-09-08T00:00:05Z"))
        XCTAssertNil(value.outputDigest)
        XCTAssertTrue(ToolEvidenceDigest.update(&value, output: "resolved", error: false, timestamp: "2026-09-08T00:00:06Z"))
        XCTAssertEqual(value.outputDigest, ToolEvidenceDigest.hash("resolved"))
    }

    func testRunBoundaryBreaksOtherwiseIdenticalCalls() {
        let events = [event("a", 0), event("b", 2), event("c", 4)]
        let result = TranscriptLoopAnalyzer.analyze(events: events, eligibleIDs: ["a", "b", "c"], sessionRef: "s", file: URL(fileURLWithPath: "/synthetic"),
            range: Date.distantPast..<Date.distantFuture, runByEventID: ["a": "r1", "b": "r1", "c": "r2"])
        XCTAssertTrue(result.isEmpty)
    }

    func testCanonicalArgumentsAndStrictErrorBoolean() {
        XCTAssertEqual(ToolEvidenceDigest.arguments("{\"b\":2,\"a\":1}"), ToolEvidenceDigest.arguments("{\"a\":1,\"b\":2}"))
        XCTAssertNotEqual(ToolEvidenceDigest.hash("full A"), ToolEvidenceDigest.hash("full B"))
        XCTAssertNil(ToolEvidenceDigest.hash(nil))
        XCTAssertNil(ToolEvidenceDigest.boolean(1))
        XCTAssertEqual(ToolEvidenceDigest.boolean(true), true)
    }
}
