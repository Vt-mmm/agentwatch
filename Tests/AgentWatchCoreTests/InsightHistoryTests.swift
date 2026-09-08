import XCTest
@testable import AgentWatchCore

final class InsightHistoryTests: XCTestCase, @unchecked Sendable {
    private func root() -> URL { FileManager.default.temporaryDirectory.appendingPathComponent("history-\(UUID())") }
    private func time(_ n: Double) -> Date { Date(timeIntervalSince1970: n) }
    private func record(_ id: String, _ n: Double, _ text: String = "context query") -> InsightHistoryRecord {
        .init(id: id, timestamp: time(n), kind: .prompt, text: text, sessionID: "session")
    }

    func testFTSReopenRangeAndProjectIsolation() async throws {
        let root = root(); defer { try? FileManager.default.removeItem(at: root) }
        let url = root.appendingPathComponent("index.sqlite")
        let store = InsightHistoryStore(url: url)
        try await store.replace(project: "a", range: time(0)..<time(100), records: [record("a", 10, "Truy vấn context"), record("b", 90, "other")])
        try await store.replace(project: "b", range: time(0)..<time(100), records: [record("a", 10, "private")])
        let reopened = InsightHistoryStore(url: url)
        let result = try await reopened.query(project: "a", range: time(5)..<time(50), search: "truy van")
        XCTAssertEqual(result.records.map(\.id), ["a"])
        XCTAssertTrue(result.fullyIndexed)
        let foreign = try await reopened.query(project: "a", range: time(0)..<time(100), search: "private")
        XCTAssertTrue(foreign.records.isEmpty)
        let syntax = try await reopened.query(project: "a", range: time(0)..<time(100), search: "\" OR *")
        XCTAssertTrue(syntax.records.isEmpty)
    }

    func testOverlappingRefreshRemovesDeletedRowsAndStaleFTSTerms() async throws {
        let root = root(); defer { try? FileManager.default.removeItem(at: root) }
        let store = InsightHistoryStore(url: root.appendingPathComponent("index.sqlite"))
        try await store.replace(project: "a", range: time(0)..<time(100), records: [record("a", 10), record("b", 50, "deleted"), record("c", 90)], warnings: ["old warning"])
        try await store.replace(project: "a", range: time(40)..<time(60), records: [record("new", 45, "replacement")])
        let all = try await store.query(project: "a", range: time(0)..<time(100))
        XCTAssertEqual(all.records.map(\.id), ["c", "new", "a"])
        XCTAssertTrue(all.fullyIndexed)
        let repaired = try await store.query(project: "a", range: time(40)..<time(60), search: "deleted")
        XCTAssertTrue(repaired.records.isEmpty)
        XCTAssertFalse(repaired.warnings.contains("old warning"))
        let outside = try await store.query(project: "a", range: time(0)..<time(40))
        XCTAssertTrue(outside.warnings.contains("old warning"))
    }

    func testCoverageGapsAndHalfOpenBoundaries() async throws {
        let root = root(); defer { try? FileManager.default.removeItem(at: root) }
        let store = InsightHistoryStore(url: root.appendingPathComponent("index.sqlite"))
        try await store.replace(project: "a", range: time(0)..<time(10), records: [record("a", 0)])
        try await store.replace(project: "a", range: time(20)..<time(30), records: [record("b", 20)])
        let gap = try await store.query(project: "a", range: time(0)..<time(30))
        XCTAssertFalse(gap.fullyIndexed)
        try await store.replace(project: "a", range: time(10)..<time(20), records: [])
        let filled = try await store.query(project: "a", range: time(0)..<time(30))
        XCTAssertTrue(filled.fullyIndexed)
        let middle = try await store.query(project: "a", range: time(10)..<time(20))
        XCTAssertTrue(middle.records.isEmpty)
        XCTAssertTrue(middle.fullyIndexed)
    }

    func testUsageDedupAndTotalsIndependentOfFTSPagination() async throws {
        let root = root(); defer { try? FileManager.default.removeItem(at: root) }
        let store = InsightHistoryStore(url: root.appendingPathComponent("index.sqlite"))
        let entry = UsageEntry(id: "request", sessionID: "s", agent: "codex", provider: "openai", modelID: "gpt-5", timestamp: time(10), tokens: UsageTokens(input: 100, output: 20, cacheRead: 50, rule: .inclusiveBreakdowns))
        let usage = InsightHistoryRecord(id: "usage", timestamp: entry.timestamp, kind: .usage, text: "gpt-5", sessionID: "s", usage: entry)
        try await store.replace(project: "a", range: time(0)..<time(20), records: [usage, usage, record("p1", 11), record("p2", 12)])
        let result = try await store.query(project: "a", range: time(0)..<time(20), search: "context", limit: 1)
        XCTAssertEqual(result.records.count, 1)
        XCTAssertTrue(result.hasMore)
        XCTAssertEqual(result.ledger.normalizedTokens.total, 120)
        let second = try await store.query(project: "a", range: time(0)..<time(20), search: "context", limit: 1, offset: 1)
        XCTAssertEqual(second.records.map(\.id), ["p1"])
        XCTAssertFalse(second.hasMore)
        XCTAssertEqual(second.ledger.normalizedTokens.total, 120)
    }

    func testInvalidRefreshPreservesPreviousSnapshot() async throws {
        let root = root(); defer { try? FileManager.default.removeItem(at: root) }
        let store = InsightHistoryStore(url: root.appendingPathComponent("index.sqlite"))
        try await store.replace(project: "a", range: time(0)..<time(20), records: [record("a", 10)])
        do {
            try await store.replace(project: "a", range: time(0)..<time(20), records: [record("invalid", 20)])
            XCTFail("Expected invalid out-of-window record")
        } catch {}
        let previous = try await store.query(project: "a", range: time(0)..<time(20))
        XCTAssertEqual(previous.records.map(\.id), ["a"])
    }

    func testLateOlderRefreshCannotOverwriteNewerIndex() async throws {
        let root = root(); defer { try? FileManager.default.removeItem(at: root) }
        let store = InsightHistoryStore(url: root.appendingPathComponent("index.sqlite"))
        try await store.replace(project: "a", range: time(0)..<time(20), records: [record("new", 10)], capturedAt: time(200))
        do {
            try await store.replace(project: "a", range: time(5)..<time(15), records: [record("old", 10)], capturedAt: time(100))
            XCTFail("Expected stale refresh rejection")
        } catch {}
        let result = try await store.query(project: "a", range: time(0)..<time(20))
        XCTAssertEqual(result.records.map(\.id), ["new"])
    }

    func testBindingChangeInvalidatesOnlySelectedProjectIncludingFTS() async throws {
        let root = root(); defer { try? FileManager.default.removeItem(at: root) }
        let store = InsightHistoryStore(url: root.appendingPathComponent("index.sqlite"))
        try await store.replace(project: "a", range: time(0)..<time(20), records: [record("a", 10)])
        try await store.replace(project: "b", range: time(0)..<time(20), records: [record("b", 10)])
        try await store.invalidate(project: "a")
        let a = try await store.query(project: "a", range: time(0)..<time(20), search: "context")
        XCTAssertTrue(a.records.isEmpty)
        XCTAssertFalse(a.fullyIndexed)
        let b = try await store.query(project: "b", range: time(0)..<time(20), search: "context")
        XCTAssertEqual(b.records.map(\.id), ["b"])
        XCTAssertTrue(b.fullyIndexed)
    }

    func testNewRangeBenchmark() async throws {
        let root = root(); defer { try? FileManager.default.removeItem(at: root) }
        let store = InsightHistoryStore(url: root.appendingPathComponent("index.sqlite"))
        let records = (0..<10_000).map { record("event-\($0)", Double($0), $0 % 100 == 0 ? "needle task" : "ordinary prompt") }
        try await store.replace(project: "a", range: time(0)..<time(10_000), records: records)
        let start = Date()
        let result = try await store.query(project: "a", range: time(500)..<time(9_500), search: "needle", limit: 100)
        let elapsed = Date().timeIntervalSince(start) * 1000
        XCTAssertEqual(result.records.count, 90)
        XCTAssertTrue(result.fullyIndexed)
        print("HISTORY_BENCH events=10000 new_range_fts_ms=\(String(format: "%.2f", elapsed))")
    }
}
