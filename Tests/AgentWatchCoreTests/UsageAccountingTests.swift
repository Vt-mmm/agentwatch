import XCTest
@testable import AgentWatchCore

final class UsageAccountingTests: XCTestCase {
    private func date(_ value: String) -> Date { ISO8601DateFormatter().date(from: value)! }
    private func entry(_ id: String, model: String = "claude-sonnet-4-6", tokens: UsageTokens = UsageTokens(input: 100, output: 20), cost: Decimal? = nil) -> UsageEntry {
        UsageEntry(id: id, sessionID: "s", agent: "claude", provider: "anthropic", modelID: model,
                   timestamp: date("2026-09-06T05:00:00Z"), tokens: tokens, agentEstimatedUSD: cost)
    }
    private func fixture(_ body: String) throws -> URL {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        let url = root.appendingPathComponent("session.jsonl")
        try body.write(to: url, atomically: true, encoding: .utf8)
        return url
    }

    func testHalfOpenVietnamDayIncludesFractionalLastSecond() throws {
        let range = ReportTime.range(for: .day(date("2026-09-06T10:00:00Z")))
        XCTAssertEqual(range.lowerBound, date("2026-09-05T17:00:00Z"))
        XCTAssertEqual(range.upperBound, date("2026-09-06T17:00:00Z"))
        XCTAssertTrue(range.contains(range.upperBound.addingTimeInterval(-0.001)))
        XCTAssertFalse(range.contains(range.upperBound))
        let url = try fixture("""
        {"type":"assistant","timestamp":"2026-09-06T16:59:59.999Z","message":{"id":"last","model":"claude-sonnet-4-6","usage":{"input_tokens":10,"output_tokens":2}}}
        {"type":"assistant","timestamp":"2026-09-06T17:00:00.000Z","message":{"id":"next","model":"claude-sonnet-4-6","usage":{"input_tokens":99,"output_tokens":9}}}
        """)
        XCTAssertEqual(JsonlParser.parseSession(at: url, range: range).totalTokens, 12)
    }

    func testBreakdownNormalizationDoesNotCountReasoningOrCacheTwice() {
        let inclusive = UsageTokens(input: 100, output: 20, cacheRead: 30, cacheWrite: 40, reasoning: 10, rule: .inclusiveBreakdowns)
        XCTAssertEqual(inclusive.total, 120)
        XCTAssertEqual(inclusive.normalized.input, 30)
        XCTAssertEqual(inclusive.normalized.total, 120)
        XCTAssertFalse(UsageTokens(input: 20, output: 1, cacheRead: 21, rule: .inclusiveBreakdowns).isValid)
        XCTAssertFalse(UsageTokens(input: 20, output: 1, reasoning: 2).isValid)
        XCTAssertFalse(UsageTokens(input: -1).isValid)
        XCTAssertFalse(UsageTokens(input: Int.max, output: 1).isValid)
    }

    func testStrictNumbersRejectBooleanFractionAndOverflowButAcceptZeroAndOneCost() throws {
        let json = try JSONSerialization.jsonObject(with: Data("{\"zero\":0,\"one\":1,\"bool\":true,\"fraction\":1.5}".utf8)) as! [String: Any]
        XCTAssertEqual(UsageIdentity.decimal(json["zero"]), 0)
        XCTAssertEqual(UsageIdentity.decimal(json["one"]), 1)
        XCTAssertNil(UsageIdentity.decimal(json["bool"]))
        XCTAssertEqual(UsageIdentity.count(json["bool"]), -1)
        XCTAssertEqual(UsageIdentity.count(json["fraction"]), -1)
        XCTAssertEqual(UsageIdentity.count("99999999999999999999999999"), -1)
        XCTAssertEqual(UsageIdentity.count(nil, required: true), -1)
    }

    func testDuplicateRequestReplacesStreamingRevisionAndModelsPriceSeparately() {
        var ledger = UsageLedger()
        ledger.upsert(entry("a", tokens: UsageTokens(input: 100, output: 1)))
        ledger.upsert(entry("a", tokens: UsageTokens(input: 100, output: 20)))
        ledger.upsert(entry("b", model: "claude-opus-4-7", tokens: UsageTokens(input: 100, output: 20)))
        XCTAssertEqual(ledger.entries.count, 2)
        XCTAssertEqual(ledger.normalizedTokens.total, 240)
        XCTAssertEqual(NSDecimalNumber(decimal: ledger.knownCostSubtotal).doubleValue, 0.0016, accuracy: 1e-12)
    }

    func testPartialCostRetainsKnownSubtotalAndUnknownModelNeverGetsFamilyFallback() {
        let ledger = UsageLedger(entries: [entry("known", cost: 0.25), entry("unknown", model: "claude-opus-unreleased")])
        XCTAssertEqual(ledger.costCoverage, .partial)
        XCTAssertEqual(ledger.knownCostSubtotal, 0.25)
        XCTAssertEqual(ledger.missingCostCount, 1)
        XCTAssertEqual(ledger.normalizedTokens.total, 240)
        XCTAssertNil(Pricing.quote(forModelId: "gpt-5.6"))
        XCTAssertNil(Pricing.quote(forModelId: "gpt-5.3-codex-spark"))
        XCTAssertEqual(entry("pi", cost: 0).costBasis, .agentEstimated)
    }

    func testLongContextRequestAndCounterDeltaHaveDifferentPriceCertainty() {
        var request = UsageEntry(id: "long", sessionID: "s", agent: "pi", provider: "openai", modelID: "gpt-6-astra",
                                 timestamp: Date(), tokens: UsageTokens(input: 300_000, output: 100))
        XCTAssertEqual(NSDecimalNumber(decimal: request.estimatedUSD!).doubleValue, 6.0075, accuracy: 1e-9)
        request.measurement = .counterDelta
        XCTAssertNil(request.estimatedUSD)
        request.modelID = "gpt-5.6-terra"; request.tokens.input = 100; request.measurement = .request
        request.provider = "anthropic"
        XCTAssertNil(request.estimatedUSD)
        XCTAssertNotNil(entry("claude-long", tokens: UsageTokens(input: 900_000, output: 1)).estimatedUSD)
    }

    func testCacheWriteTTLPricesOnlyOneHourSubsetAtOneHourRate() {
        let request = entry("cache", tokens: UsageTokens(input: 0, output: 0, cacheWrite: 200, cacheWrite1h: 100))
        XCTAssertEqual(NSDecimalNumber(decimal: request.estimatedUSD!).doubleValue, 0.000975, accuracy: 1e-12)
    }

    func testOverflowCannotCrashAggregation() {
        let ledger = UsageLedger(entries: [entry("a", tokens: UsageTokens(input: Int.max / 2)), entry("b", tokens: UsageTokens(input: Int.max / 2)), entry("c", tokens: UsageTokens(input: 10))])
        XCTAssertTrue(ledger.hasPartialUsage)
        XCTAssertTrue(ledger.warnings.contains { $0.contains("overflow") })
    }

    func testMalformedAndMissingUsageAreVisibleAsPartial() throws {
        let url = try fixture("""
        not-json
        {"type":"assistant","timestamp":"2026-09-06T05:00:00Z","message":{"id":"missing","model":"claude-sonnet-4-6"}}
        """)
        let parsed = JsonlParser.parseSession(at: url)
        XCTAssertTrue(parsed.usageLedger.hasPartialUsage)
        XCTAssertEqual(parsed.usageLedger.costCoverage, .unavailable)
        XCTAssertEqual(parsed.totalTokens, 0)
        let manifest = SourceFileManifest.inspect(url)
        XCTAssertEqual(manifest.malformedRecordCount, 1)
        XCTAssertTrue(manifest.readable)
        XCTAssertEqual(manifest.sha256?.count, 64)
    }

    func testCodexResetPreservesKnownSegmentsAndMarksPartial() throws {
        let url = try fixture("""
        {"type":"session_meta","timestamp":"2026-09-06T01:00:00Z","payload":{"id":"codex-reset","model_provider":"openai"}}
        {"type":"turn_context","timestamp":"2026-09-06T01:00:01Z","payload":{"model":"gpt-5.6-sol"}}
        {"type":"event_msg","timestamp":"2026-09-06T01:01:00Z","payload":{"type":"token_count","info":{"total_token_usage":{"input_tokens":100,"output_tokens":20}}}}
        {"type":"event_msg","timestamp":"2026-09-06T01:02:00Z","payload":{"type":"token_count","info":{"total_token_usage":{"input_tokens":10,"output_tokens":2}}}}
        {"type":"event_msg","timestamp":"2026-09-06T01:03:00Z","payload":{"type":"token_count","info":{"total_token_usage":{"input_tokens":30,"output_tokens":5}}}}
        """)
        let summary = try XCTUnwrap(CodexJsonlParser.summarize(file: url, range: date("2026-09-06T00:00:00Z")..<date("2026-09-07T00:00:00Z")))
        XCTAssertEqual(summary.totalTokens, 143) // Known 120 before reset + 23 after reset.
        XCTAssertEqual(summary.usageScope, .partialRange)
        XCTAssertEqual(SessionInventory.aggregate([summary, summary]).totalTokens, 143)
        XCTAssertEqual(SessionAccounting.canonical([summary, summary]).count, 1)
    }

    func testCodexMissingBaselineKeepsLaterKnownDelta() throws {
        let url = try fixture("""
        {"type":"session_meta","timestamp":"2026-09-05T01:00:00Z","payload":{"id":"old","model_provider":"openai"}}
        {"type":"turn_context","timestamp":"2026-09-05T01:00:01Z","payload":{"model":"gpt-5.6-sol"}}
        {"type":"event_msg","timestamp":"2026-09-06T01:01:00Z","payload":{"type":"token_count","info":{"total_token_usage":{"input_tokens":1000,"output_tokens":200}}}}
        {"type":"event_msg","timestamp":"2026-09-06T01:02:00Z","payload":{"type":"token_count","info":{"total_token_usage":{"input_tokens":1100,"output_tokens":220}}}}
        """)
        let summary = try XCTUnwrap(CodexJsonlParser.summarize(file: url, range: date("2026-09-06T00:00:00Z")..<date("2026-09-07T00:00:00Z")))
        XCTAssertEqual(summary.totalTokens, 120)
        XCTAssertEqual(summary.usageScope, .partialRange)
    }

    func testCodexForkInheritedHistoryIsNotNewConsumption() throws {
        let url = try fixture("""
        {"type":"session_meta","timestamp":"2026-09-06T02:00:00Z","payload":{"id":"fork","forked_from_id":"parent","timestamp":"2026-09-06T02:00:00Z","model_provider":"openai"}}
        {"type":"turn_context","timestamp":"2026-09-06T01:00:01Z","payload":{"model":"gpt-5.6-sol"}}
        {"type":"event_msg","timestamp":"2026-09-06T01:01:00Z","payload":{"type":"token_count","info":{"total_token_usage":{"input_tokens":100,"output_tokens":20}}}}
        {"type":"event_msg","timestamp":"2026-09-06T02:01:00Z","payload":{"type":"token_count","info":{"total_token_usage":{"input_tokens":110,"output_tokens":22}}}}
        """)
        let summary = try XCTUnwrap(CodexJsonlParser.summarize(file: url, range: date("2026-09-06T00:00:00Z")..<date("2026-09-07T00:00:00Z")))
        XCTAssertEqual(summary.totalTokens, 12)
        XCTAssertEqual(summary.usageScope, .partialRange)
    }

    func testPiForkExcludesInheritedMessagesAndSessionLocalIDsDoNotCollide() throws {
        let url = try fixture("""
        {"type":"session","id":"fork","timestamp":"2026-09-06T02:00:00Z","cwd":"/synthetic","parentSession":"/not-read/parent.jsonl"}
        {"type":"message","id":"old-user","timestamp":"2026-09-06T01:00:00Z","message":{"role":"user","content":[{"type":"text","text":"Copied prompt"}]}}
        {"type":"message","id":"deadbeef","timestamp":"2026-09-06T01:01:00Z","message":{"role":"assistant","provider":"openai","model":"gpt-5.6-sol","usage":{"input":100,"output":20}}}
        {"type":"message","id":"new-user","timestamp":"2026-09-06T02:00:01Z","message":{"role":"user","content":[{"type":"text","text":"New prompt"}]}}
        {"type":"message","id":"cafebabe","timestamp":"2026-09-06T02:01:00Z","message":{"role":"assistant","provider":"openai","model":"gpt-5.6-sol","usage":{"input":10,"output":2}}}
        """)
        let summary = try XCTUnwrap(PiAgentJsonlParser.summarize(file: url, range: date("2026-09-06T00:00:00Z")..<date("2026-09-07T00:00:00Z")))
        XCTAssertEqual(summary.totalTokens, 12); XCTAssertEqual(summary.promptCount, 1)
        XCTAssertTrue(summary.dataWarnings.contains { $0.contains("fork") })
        XCTAssertTrue(summary.usageEntries?.first?.id.contains("fork|entry|cafebabe") == true)
    }

    @MainActor
    func testFullScanFindsChildLogsAndOldMtimeCopyWithoutCountingChildPrompt() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let roots = AgentLogRoots(home: root.path, environment: [:])
        let file = URL(fileURLWithPath: roots.claudeProjects).appendingPathComponent("project/parent/subagents/child.jsonl")
        try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        try """
        {"type":"user","timestamp":"2026-09-06T05:00:00Z","message":{"content":"Investigate child task"}}
        {"type":"assistant","timestamp":"2026-09-06T05:01:00Z","message":{"id":"child-request","model":"claude-sonnet-4-6","usage":{"input_tokens":10,"output_tokens":2}}}
        """.write(to: file, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.modificationDate: Date.distantPast], ofItemAtPath: file.path)
        let result = await CoachingScan.scan(in: date("2026-09-06T00:00:00Z")..<date("2026-09-07T00:00:00Z"), roots: roots, captureManifest: true)
        XCTAssertEqual(result.sessions.count, 1)
        XCTAssertEqual(result.sessions.first?.totalTokens, 12)
        XCTAssertTrue(result.prompts.isEmpty)
        XCTAssertEqual(result.sourceFiles.count, 1)
        XCTAssertTrue(result.sourceRoots.contains { !$0.exists })
    }

    func testConfiguredRootsOverrideHomeWithoutReadingCredentials() {
        let roots = AgentLogRoots(home: "/tmp/home", environment: ["CLAUDE_CONFIG_DIR": "/tmp/cc", "CODEX_HOME": "/tmp/cx", "PI_CODING_AGENT_SESSION_DIR": "/tmp/pi"])
        XCTAssertEqual(roots.claudeProjects, "/tmp/cc/projects")
        XCTAssertEqual(roots.codexArchived, "/tmp/cx/archived_sessions")
        XCTAssertEqual(roots.piSessions, "/tmp/pi")
    }
}
