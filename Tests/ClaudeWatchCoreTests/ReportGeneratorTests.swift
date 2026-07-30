import XCTest
@testable import ClaudeWatchCore

final class ReportGeneratorTests: XCTestCase {

    private func makeRecord(id: String = UUID().uuidString,
                            text: String, project: String = "ws/api",
                            sessionTitle: String? = nil,
                            sessionUuid: String = "abc",
                            source: SessionSource = .cli,
                            offsetSeconds: TimeInterval = 0) -> PromptRecord {
        let score = PromptScorer.score(text)
        return PromptRecord(
            id: id,
            timestamp: Date(timeIntervalSinceReferenceDate: 700_000_000 + offsetSeconds),
            projectSlug: "-Users-tam-Documents-\(project.replacingOccurrences(of: "/", with: "-"))",
            projectDisplay: "/Users/tam/Documents/\(project)",
            sessionTitle: sessionTitle,
            sessionUuid: sessionUuid,
            text: text, score: score,
            source: source
        )
    }

    func testStatsAggregateTaskAndFollowUp() {
        let records: [PromptRecord] = [
            makeRecord(text: "test giúp em đi", offsetSeconds: 0),
            makeRecord(text: """
                ## Mục tiêu
                Sửa bug
                ## Role
                Admin
                ## Input
                id
                ## Output
                200/404
                ## Flow
                check
                ## Edge Case
                missing
                ## constrained_by
                schema X
                ## Definition of Done
                pass tests và không phá tính năng cũ. Cần có audit log đầy đủ.
                """, offsetSeconds: 60),
            makeRecord(text: String(repeating: "x", count: 600), offsetSeconds: 120),
        ]
        let s = ReportGenerator.stats(for: records)
        XCTAssertEqual(s.totalPrompts, 3)
        XCTAssertEqual(s.taskPrompts, 2)
        XCTAssertEqual(s.followUpPrompts, 1)
        XCTAssertGreaterThan(s.avgStars, 0)
    }

    func testMarkdownContainsAllSectionsAndPrompts() {
        let records = [makeRecord(text: "## Mục tiêu\nfix bug\n## Role\nadmin")]
        let md = ReportGenerator.markdown(scope: .day(Date()), records: records)
        XCTAssertTrue(md.contains("AGENT WATCH REPORT"))
        XCTAssertTrue(md.contains("Phân bổ chất lượng"))
        XCTAssertTrue(md.contains("Breakdown theo project"))
        XCTAssertTrue(md.contains("Mục tiêu"))    // section name in detail
    }

    func testHTMLIsWellFormedWithSummaryCards() {
        let records = [makeRecord(text: "Hi em")]
        let html = ReportGenerator.html(scope: .day(Date()), records: records)
        XCTAssertTrue(html.contains("<!DOCTYPE html>"))
        XCTAssertTrue(html.contains("Tổng prompts"))
        XCTAssertTrue(html.contains("</html>"))
    }

    func testEmptyRangeProducesValidReportNotCrash() {
        let s = ReportGenerator.stats(for: [])
        XCTAssertEqual(s.totalPrompts, 0)
        XCTAssertEqual(s.avgStars, 0)
        let md = ReportGenerator.markdown(scope: .day(Date()), records: [])
        XCTAssertTrue(md.contains("Không có prompt"))
    }

    func testReportKeepsSameRawSessionAndPromptIdsSeparateAcrossAgents() {
        let codexPrompt = makeRecord(
            id: "same-prompt",
            text: "Codex task prompt",
            sessionUuid: "same-session",
            source: .codex
        )
        let piPrompt = makeRecord(
            id: "same-prompt",
            text: "Pi task prompt",
            sessionTitle: "APP-101",
            sessionUuid: "same-session",
            source: .piagent
        )
        let timestamp = codexPrompt.timestamp
        let sessions = [
            SessionSummary(
                id: "same-session",
                projectDisplay: "/workspace",
                source: .codex,
                model: "gpt-5.3-codex",
                modelFamily: .gpt,
                inputTokens: 10,
                outputTokens: 2,
                cacheReadTokens: 0,
                cacheWriteTokens: 0,
                cost: 0.0000455,
                firstTimestamp: timestamp,
                lastTimestamp: timestamp,
                promptCount: 1,
                toolCallCount: 0
            ),
            SessionSummary(
                id: "same-session",
                sessionTitle: "APP-101",
                titleHistory: [
                    SessionTitleChange(
                        timestamp: timestamp,
                        timestampString: "",
                        title: "WRONG"
                    ),
                    SessionTitleChange(
                        timestamp: timestamp.addingTimeInterval(300),
                        timestampString: "",
                        title: "APP-101"
                    ),
                ],
                projectDisplay: "/workspace",
                source: .piagent,
                model: "claude-sonnet",
                modelFamily: .sonnet,
                inputTokens: 10,
                outputTokens: 2,
                cacheReadTokens: 0,
                cacheWriteTokens: 0,
                cost: 0.00006,
                firstTimestamp: timestamp,
                lastTimestamp: timestamp,
                promptCount: 1,
                toolCallCount: 0
            ),
        ]

        let md = ReportGenerator.markdown(
            scope: .day(timestamp),
            records: [codexPrompt, piPrompt],
            sessions: sessions
        )

        XCTAssertTrue(md.contains("Codex task prompt"))
        XCTAssertTrue(md.contains("Pi task prompt"))
        XCTAssertTrue(md.contains("Name history"))
        XCTAssertTrue(md.contains("WRONG"))
        XCTAssertTrue(md.contains("APP-101"))
        XCTAssertFalse(md.contains("Prompts chưa map được session summary"))
    }

    func testCSVIncludesTaskThinkingAndReasoningColumns() {
        let record = makeRecord(
            text: "Implement payment audit",
            sessionTitle: "PAY-742 Payment audit"
        )
        let session = SessionSummary(
            id: "abc",
            sessionTitle: "PAY-742 Payment audit",
            projectDisplay: "/Users/tam/Documents/ws/api",
            source: .piagent,
            model: "gpt-5",
            modelFamily: .gpt,
            inputTokens: 100,
            outputTokens: 20,
            reasoningTokens: 30,
            cacheReadTokens: 40,
            cacheWriteTokens: 10,
            cost: 0.12,
            firstTimestamp: record.timestamp,
            lastTimestamp: record.timestamp,
            promptCount: 1,
            toolCallCount: 2,
            thinkingLevel: "max"
        )

        let csv = ReportGenerator.csv(records: [record], sessions: [session])
        let lines = csv.split(separator: "\n").map(String.init)
        let expectedColumns = lines[0].split(separator: ",", omittingEmptySubsequences: false).count

        XCTAssertTrue(lines[0].contains("session_title"))
        XCTAssertTrue(lines[0].contains("thinking_level"))
        XCTAssertTrue(lines[0].contains("reasoning_tokens"))
        XCTAssertTrue(lines[0].contains("cost_basis"))
        XCTAssertTrue(lines[0].contains("token_formula"))
        XCTAssertTrue(lines[0].contains("usage_scope"))
        XCTAssertTrue(lines[0].contains("source_file"))
        XCTAssertTrue(csv.contains("PAY-742 Payment audit"))
        XCTAssertTrue(csv.contains("max"))
        for line in lines {
            XCTAssertEqual(
                line.split(separator: ",", omittingEmptySubsequences: false).count,
                expectedColumns
            )
        }
    }

    func testExportIncludesEveryToolActionInSelectedRange() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let file = directory.appendingPathComponent("tool-audit.jsonl")
        let raw = """
        {"type":"assistant","timestamp":"2026-07-30T02:00:00.000Z","message":{"model":"claude-sonnet-4","usage":{"input_tokens":10,"output_tokens":2},"content":[{"type":"tool_use","id":"tool-1","name":"Bash","input":{"command":"swift test"}}]}}
        {"type":"user","timestamp":"2026-07-30T02:00:01.000Z","message":{"content":[{"type":"tool_result","tool_use_id":"tool-1","content":"32 tests passed"}]}}
        """
        try raw.write(to: file, atomically: true, encoding: .utf8)

        let iso = ISO8601DateFormatter()
        iso.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let timestamp = try XCTUnwrap(iso.date(from: "2026-07-30T02:00:00.000Z"))
        let scope = ReportScope.day(timestamp)
        let session = SessionSummary(
            id: "tool-audit",
            sessionTitle: "AW-42 Tool audit",
            projectDisplay: "/workspace/agent-watch",
            source: .cli,
            model: "claude-sonnet-4",
            modelFamily: .sonnet,
            inputTokens: 10,
            outputTokens: 2,
            cacheReadTokens: 0,
            cacheWriteTokens: 0,
            cost: 0.00006,
            firstTimestamp: timestamp,
            lastTimestamp: timestamp,
            promptCount: 0,
            toolCallCount: 1,
            fileURL: file,
            costBasis: .estimated,
            usageScope: .exactRange
        )

        let markdown = ReportGenerator.markdown(
            scope: scope,
            records: [],
            sessions: [session],
            includeToolAudit: true
        )
        XCTAssertTrue(markdown.contains("Tool activity audit (1)"))
        XCTAssertTrue(markdown.contains("Bash"))
        XCTAssertTrue(markdown.contains("32 tests passed"))

        let csv = ReportGenerator.csv(
            records: [],
            sessions: [session],
            scope: scope,
            includeToolAudit: true
        )
        XCTAssertTrue(csv.contains("tool_action"))
        XCTAssertTrue(csv.contains("swift test"))
        let rows = csv.split(separator: "\n").map(String.init)
        let columnCount = rows[0].split(separator: ",", omittingEmptySubsequences: false).count
        for row in rows {
            XCTAssertEqual(
                row.split(separator: ",", omittingEmptySubsequences: false).count,
                columnCount
            )
        }
    }
}
