// Smoke tests for the JSONL parser. Uses synthetic fixtures in a temp dir
// to avoid depending on the user's real ~/.claude/projects.

import XCTest
@testable import ClaudeWatchCore

final class JsonlParserTests: XCTestCase {

    private func writeFixture(_ lines: [[String: Any]]) throws -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("claude-watch-tests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let url = dir.appendingPathComponent("session.jsonl")
        let body = lines.map {
            String(data: try! JSONSerialization.data(withJSONObject: $0), encoding: .utf8)!
        }.joined(separator: "\n")
        try body.write(to: url, atomically: true, encoding: .utf8)
        return url
    }

    func testAggregatesTokensAcrossAssistantMessages() throws {
        let url = try writeFixture([
            [
                "type": "assistant",
                "timestamp": "2026-06-12T01:00:00.000Z",
                "message": [
                    "model": "claude-opus-4-7",
                    "usage": [
                        "input_tokens": 100,
                        "output_tokens": 50,
                        "cache_read_input_tokens": 1000,
                        "cache_creation_input_tokens": 2000,
                    ],
                    "content": [["type": "text", "text": "hi"]],
                ],
            ],
            [
                "type": "assistant",
                "timestamp": "2026-06-12T01:00:10.000Z",
                "message": [
                    "model": "claude-opus-4-7",
                    "usage": [
                        "input_tokens": 5,
                        "output_tokens": 200,
                        "cache_read_input_tokens": 500,
                        "cache_creation_input_tokens": 0,
                    ],
                    "content": [],
                ],
            ],
        ])
        let s = JsonlParser.parseSession(at: url)
        XCTAssertEqual(s.messageCount, 2)
        XCTAssertEqual(s.inputTokens, 105)
        XCTAssertEqual(s.outputTokens, 250)
        XCTAssertEqual(s.cacheReadTokens, 1500)
        XCTAssertEqual(s.cacheWriteTokens, 2000)
        XCTAssertEqual(s.model, "claude-opus-4-7")
        XCTAssertEqual(s.modelFamily, .opus)
        let expected = Pricing.cost(
            family: .opus, inputTokens: 105, outputTokens: 250,
            cacheReadTokens: 1500, cacheWriteTokens: 2000
        )
        XCTAssertEqual(s.cost, expected, accuracy: 1e-9)
    }

    func testTracksActiveVsCompletedAgents() throws {
        let url = try writeFixture([
            [
                "type": "assistant",
                "timestamp": "2026-06-12T02:00:00.000Z",
                "message": [
                    "model": "claude-opus-4-7",
                    "usage": ["input_tokens": 1, "output_tokens": 1],
                    "content": [
                        [
                            "type": "tool_use",
                            "id": "agent_1",
                            "name": "Agent",
                            "input": [
                                "subagent_type": "Explore",
                                "description": "scout",
                                "prompt": "Find all files matching X",
                            ],
                        ],
                        [
                            "type": "tool_use",
                            "id": "agent_2",
                            "name": "Agent",
                            "input": ["subagent_type": "code-reviewer", "description": "review"],
                        ],
                    ],
                ],
            ],
            [
                "type": "user",
                "timestamp": "2026-06-12T02:00:10.000Z",
                "message": [
                    "content": [[
                        "type": "tool_result",
                        "tool_use_id": "agent_1",
                        "content": "Found 3 files",
                    ]],
                ],
            ],
        ])
        let s = JsonlParser.parseSession(at: url)
        XCTAssertEqual(s.agents.count, 2)
        XCTAssertEqual(s.activeAgents.count, 1)
        XCTAssertEqual(s.activeAgents.first?.subagentType, "code-reviewer")
        let done = s.completedAgents.first
        XCTAssertEqual(done?.subagentType, "Explore")
        XCTAssertEqual(done?.prompt, "Find all files matching X")
        XCTAssertEqual(done?.completedAt, "2026-06-12T02:00:10.000Z")
        XCTAssertEqual(done?.resultSnippet, "Found 3 files")
    }

    func testModelFamilyDetection() {
        XCTAssertEqual(ModelFamily.from(modelId: "claude-opus-4-7"), .opus)
        XCTAssertEqual(ModelFamily.from(modelId: "claude-sonnet-4-6"), .sonnet)
        XCTAssertEqual(ModelFamily.from(modelId: "claude-haiku-4-5-20251001"), .haiku)
        XCTAssertEqual(ModelFamily.from(modelId: "claude-fable-5"), .fable)
        XCTAssertEqual(ModelFamily.from(modelId: nil), .unknown)
        XCTAssertEqual(ModelFamily.from(modelId: "gpt-4"), .gpt)
    }

    func testSkipsMalformedLines() throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("cw-malformed-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let url = dir.appendingPathComponent("session.jsonl")
        let good = """
        {"type":"assistant","timestamp":"2026-06-12T03:00:00Z","message":{"model":"claude-sonnet-4-6","usage":{"input_tokens":10,"output_tokens":20},"content":[]}}
        """
        let body = "garbage not json\n\(good)\n{half broken\n\(good)\n"
        try body.write(to: url, atomically: true, encoding: .utf8)

        let s = JsonlParser.parseSession(at: url)
        XCTAssertEqual(s.messageCount, 2)
        XCTAssertEqual(s.inputTokens, 20)
        XCTAssertEqual(s.outputTokens, 40)
        XCTAssertEqual(s.modelFamily, .sonnet)
    }

    func testSlugReplacesSlashUnderscoreAndDot() {
        XCTAssertEqual(
            ProjectPath.slug(for: URL(fileURLWithPath: "/Users/vtamm/Documents/Working")),
            "-Users-vtamm-Documents-Working"
        )
        // Underscore in folder name → hyphen in slug (Claude Code's actual rule).
        XCTAssertEqual(
            ProjectPath.slug(for: URL(fileURLWithPath: "/Users/vtamm/Documents/Claude_management")),
            "-Users-vtamm-Documents-Claude-management"
        )
        // Dot too — explains the double hyphen in worktree paths like `.claude-worktrees`.
        XCTAssertEqual(
            ProjectPath.slug(for: URL(fileURLWithPath: "/x/.claude/y")),
            "-x--claude-y"
        )
    }
}
