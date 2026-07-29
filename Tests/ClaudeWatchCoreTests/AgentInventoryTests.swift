import XCTest
@testable import ClaudeWatchCore

final class AgentInventoryTests: XCTestCase {
    private func makeTempDir(_ name: String = "agent-inventory") throws -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("\(name)-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    private func writeJSONL(_ lines: [[String: Any]], to url: URL) throws {
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        let body = lines.map {
            String(data: try! JSONSerialization.data(withJSONObject: $0), encoding: .utf8)!
        }.joined(separator: "\n")
        try body.write(to: url, atomically: true, encoding: .utf8)
    }

    func testPiAgentInventorySummarizesUsagePromptsAndToolTimeline() throws {
        let root = try makeTempDir()
        let file = root
            .appendingPathComponent("--Users-test-Work", isDirectory: true)
            .appendingPathComponent("2026-07-29T01-00-00-000Z_session.jsonl")
        try writeJSONL([
            [
                "type": "session",
                "id": "pi-session-1",
                "timestamp": "2026-07-29T01:00:00.000Z",
                "cwd": "/Users/test/Work",
            ],
            [
                "type": "model_change",
                "timestamp": "2026-07-29T01:00:01.000Z",
                "modelId": "gpt-5.5",
            ],
            [
                "type": "thinking_level_change",
                "timestamp": "2026-07-29T01:00:01.200Z",
                "thinkingLevel": "max",
            ],
            [
                "type": "session_info",
                "timestamp": "2026-07-29T01:00:01.500Z",
                "name": "pi:PAY-742 Payment audit",
            ],
            [
                "type": "message",
                "timestamp": "2026-07-29T01:00:02.000Z",
                "message": [
                    "role": "user",
                    "content": [["type": "text", "text": "Implement payment audit report"]],
                ],
            ],
            [
                "type": "message",
                "timestamp": "2026-07-29T01:00:03.000Z",
                "message": [
                    "role": "assistant",
                    "model": "gpt-5.5",
                    "usage": [
                        "input": 10,
                        "output": 20,
                        "reasoning": 50,
                        "cacheRead": 30,
                        "cacheWrite": 40,
                        "cost": ["total": 0.123],
                    ],
                    "content": [[
                        "type": "toolCall",
                        "id": "tool-1",
                        "name": "bash",
                        "arguments": ["command": "swift test"],
                    ]],
                ],
            ],
            [
                "type": "message",
                "timestamp": "2026-07-29T01:00:04.000Z",
                "message": [
                    "role": "toolResult",
                    "toolCallId": "tool-1",
                    "toolName": "bash",
                    "content": [["type": "text", "text": "passed"]],
                ],
            ],
        ], to: file)

        let range = iso("2026-07-29T00:00:00.000Z")!...iso("2026-07-29T02:00:00.000Z")!
        let sessions = PiAgentInventory.list(in: range, root: root.path)

        XCTAssertEqual(sessions.count, 1)
        let summary = try XCTUnwrap(sessions.first)
        XCTAssertEqual(summary.id, "pi-session-1")
        XCTAssertEqual(summary.source, .piagent)
        XCTAssertEqual(summary.sessionTitle, "PAY-742 Payment audit")
        XCTAssertTrue(summary.hasTaskSessionTitle)
        XCTAssertEqual(summary.model, "gpt-5.5")
        XCTAssertEqual(summary.thinkingLevel, "max")
        XCTAssertEqual(summary.inputTokens, 10)
        XCTAssertEqual(summary.outputTokens, 20)
        XCTAssertEqual(summary.reasoningTokens, 50)
        XCTAssertEqual(summary.totalTokens, 150)
        XCTAssertEqual(summary.cacheReadTokens, 30)
        XCTAssertEqual(summary.cacheWriteTokens, 40)
        XCTAssertEqual(summary.cost, 0.123, accuracy: 0.000001)
        XCTAssertEqual(summary.promptCount, 1)
        XCTAssertEqual(summary.toolCallCount, 1)

        let prompts = PiAgentJsonlParser.extractPrompts(from: file, range: range)
        XCTAssertEqual(prompts.map(\.text), ["Implement payment audit report"])
        XCTAssertEqual(prompts.first?.sessionTitle, "PAY-742 Payment audit")

        let detail = PiAgentJsonlParser.parseSession(at: file)
        XCTAssertEqual(detail.sessionName, "PAY-742 Payment audit")
        XCTAssertEqual(detail.thinkingLevel, "max")
        XCTAssertEqual(detail.reasoningTokens, 50)
        let tool = try XCTUnwrap(detail.events.first(where: { $0.kind == .toolUse }))
        XCTAssertEqual(tool.toolName, "bash")
        XCTAssertTrue(tool.completed)
        XCTAssertEqual(tool.resultPreview, "passed")
    }

    func testCodexInventoryUsesTurnModelCacheWriteAndCustomToolCalls() throws {
        let root = try makeTempDir()
        let file = root
            .appendingPathComponent("2026/07/29", isDirectory: true)
            .appendingPathComponent("rollout-2026-07-29T01-00-00-test.jsonl")
        try writeJSONL([
            [
                "timestamp": "2026-07-29T01:00:00.000Z",
                "type": "session_meta",
                "payload": [
                    "id": "codex-session-1",
                    "cwd": "/Users/test/Work",
                    "model_provider": "openai",
                ],
            ],
            [
                "timestamp": "2026-07-29T01:00:01.000Z",
                "type": "turn_context",
                "payload": ["model": "gpt-5.6-sol", "effort": "high"],
            ],
            [
                "timestamp": "2026-07-29T01:00:02.000Z",
                "type": "response_item",
                "payload": [
                    "type": "message",
                    "role": "user",
                    "content": [["type": "text", "text": "Review token burn risk"]],
                ],
            ],
            [
                "timestamp": "2026-07-29T01:00:02.500Z",
                "type": "event_msg",
                "payload": [
                    "type": "user_message",
                    "message": "Review token burn risk",
                ],
            ],
            [
                "timestamp": "2026-07-29T01:00:03.000Z",
                "type": "response_item",
                "payload": [
                    "type": "custom_tool_call",
                    "call_id": "call-1",
                    "name": "bash",
                    "input": "swift test",
                ],
            ],
            [
                "timestamp": "2026-07-29T01:00:04.000Z",
                "type": "response_item",
                "payload": [
                    "type": "custom_tool_call_output",
                    "call_id": "call-1",
                    "output": "passed",
                ],
            ],
            [
                "timestamp": "2026-07-29T01:00:05.000Z",
                "type": "event_msg",
                "payload": [
                    "type": "token_count",
                    "info": [
                        "total_token_usage": [
                            "input_tokens": 100,
                            "output_tokens": 20,
                            "reasoning_output_tokens": 50,
                            "cached_input_tokens": 30,
                            "cache_write_input_tokens": 40,
                        ],
                    ],
                ],
            ],
        ], to: file)

        let range = iso("2026-07-29T00:00:00.000Z")!...iso("2026-07-29T02:00:00.000Z")!
        let sessions = CodexInventory.list(in: range, root: root.path)

        XCTAssertEqual(sessions.count, 1)
        let summary = try XCTUnwrap(sessions.first)
        XCTAssertEqual(summary.id, "codex-session-1")
        XCTAssertEqual(summary.model, "gpt-5.6-sol")
        XCTAssertEqual(summary.thinkingLevel, "high")
        XCTAssertEqual(summary.inputTokens, 100)
        XCTAssertEqual(summary.outputTokens, 20)
        XCTAssertEqual(summary.reasoningTokens, 50)
        XCTAssertEqual(summary.totalTokens, 240)
        XCTAssertEqual(summary.cacheReadTokens, 30)
        XCTAssertEqual(summary.cacheWriteTokens, 40)
        XCTAssertEqual(summary.promptCount, 1)
        XCTAssertEqual(summary.toolCallCount, 1)

        let prompts = CodexJsonlParser.extractPrompts(from: file, range: range)
        XCTAssertEqual(prompts.map(\.text), ["Review token burn risk"])

        let detail = CodexJsonlParser.parseSession(at: file)
        XCTAssertEqual(detail.thinkingLevel, "high")
        XCTAssertEqual(detail.reasoningTokens, 50)
        XCTAssertEqual(detail.events.filter { $0.kind == .userMessage }.count, 1)
        let tool = try XCTUnwrap(detail.events.first(where: { $0.kind == .toolUse }))
        XCTAssertEqual(tool.toolName, "bash")
        XCTAssertTrue(tool.completed)
        XCTAssertEqual(tool.resultPreview, "passed")
    }

    private func iso(_ raw: String) -> Date? {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f.date(from: raw)
    }
}
