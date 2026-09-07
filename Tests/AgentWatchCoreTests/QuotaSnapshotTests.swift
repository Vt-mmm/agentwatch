import XCTest
@testable import AgentWatchCore

final class QuotaSnapshotTests: XCTestCase {
    func testAppServerHandshakeOnlyRequestsQuotaAndHandlesMissingCapability() {
        var exchange = CodexQuotaExchange()
        XCTAssertEqual(CodexQuotaExchange.initialize["method"] as? String, "initialize")
        let requests = exchange.receive(["id": 1, "result": ["userAgent": "codex-test"]])
        XCTAssertEqual(requests.compactMap { $0["method"] as? String }, ["initialized", "account/rateLimits/read"])
        XCTAssertTrue(exchange.receive(["method": "thread/started", "params": [:]]).isEmpty)
        _ = exchange.receive(["id": 2, "error": ["code": -32601, "message": "method missing"]])
        XCTAssertEqual(exchange.result?.availability, .unsupported)
        XCTAssertTrue(exchange.result?.windows.isEmpty == true)
    }
    func testAppServerSuccessAndFailureDoNotLeakProviderMessages() {
        var success = CodexQuotaExchange()
        _ = success.receive(["id": 1, "result": [:]])
        _ = success.receive(["id": 2, "result": ["rateLimits": ["primary": ["usedPercent": 20]]]])
        XCTAssertEqual(success.result?.windows.first?.remainingPercent, 80)
        var failure = CodexQuotaExchange()
        _ = failure.receive(["id": 1, "error": ["code": 500, "message": "sensitive-provider-debug"]])
        XCTAssertEqual(failure.result?.availability, .failed)
        XCTAssertFalse(failure.result?.warnings.joined().contains("sensitive-provider-debug") ?? true)
    }
    func testMissingFieldsAreUnknownAndNotFullQuota() {
        let s = QuotaParser.claudeStatusLine(["context_window": ["used_percentage": 80]])
        XCTAssertEqual(s.availability, .unavailable)
        XCTAssertTrue(s.windows.isEmpty)
        XCTAssertEqual(QuotaParser.pi().availability, .unsupported)
    }
    func testCodexMultiBucketDoesNotDoubleCountLegacyMirror() {
        let raw: [String: Any] = ["accountId": "private-account", "rateLimits": ["primary": ["usedPercent": 99]],
                                 "rateLimitsByLimitId": ["codex": ["primary": ["usedPercent": 25, "windowDurationMins": 300]], "review": ["secondary": ["usedPercent": 50]]]]
        let s = QuotaParser.codex(raw)
        XCTAssertEqual(s.windows.count, 2)
        XCTAssertEqual(s.windows.map(\.usedPercent), [25, 50])
        XCTAssertNotEqual(s.accountKey, "private-account")
        XCTAssertNil(s.windows[1].resetsAt)
    }
    func testFreshnessExpiresAtResetWithoutInventingNewQuota() {
        let now = Date(timeIntervalSince1970: 1000)
        let s = QuotaParser.claudeStatusLine(["rate_limits": ["five_hour": ["used_percentage": 105, "resets_at": 1100]]], at: now)
        XCTAssertFalse(s.isStale(at: now))
        XCTAssertTrue(s.isStale(at: Date(timeIntervalSince1970: 1100)))
        XCTAssertEqual(s.windows.first?.usedPercent, 105)
        XCTAssertEqual(s.windows.first?.remainingPercent, 0)
    }
    func testMalformedPercentDoesNotBecomeZeroAndStoreDropsRawPayload() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = QuotaSnapshotStore(root: root)
        let s = QuotaParser.claudeStatusLine(["secret": "never-persist-this", "rate_limits": ["five_hour": ["used_percentage": true]]])
        XCTAssertEqual(s.availability, .unavailable)
        XCTAssertNil(s.windows.first?.usedPercent)
        try store.save(s)
        XCTAssertEqual(try store.load(), [s])
        let file = try FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: nil)[0]
        XCTAssertFalse(try String(contentsOf: file, encoding: .utf8).contains("never-persist-this"))
    }
}
