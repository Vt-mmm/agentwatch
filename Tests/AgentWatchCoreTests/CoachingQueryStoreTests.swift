import XCTest
@testable import AgentWatchCore

final class CoachingQueryStoreTests: XCTestCase, @unchecked Sendable {
    private struct Fixture {
        let dir: URL
        let roots: AgentLogRoots
        let databaseURL: URL
        let files: [URL]
        let range: Range<Date>
        var store: CoachingQueryStore { CoachingQueryStore(url: databaseURL) }
    }

    private func fixture() throws -> Fixture {
        let dir = FileManager.default.temporaryDirectory.resolvingSymlinksInPath().appendingPathComponent("agentwatch-query-\(UUID())")
        let roots = AgentLogRoots(home: dir.path, environment: [:])
        let paths = [roots.claudeProjects + "/project/claude.jsonl",
                     roots.codexSessions + "/codex.jsonl", roots.piSessions + "/pi.jsonl"]
        let files = paths.map { URL(fileURLWithPath: $0) }
        for file in files {
            try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        }
        let start = ISO8601DateFormatter().date(from: "2026-09-08T00:00:00Z")!
        return Fixture(dir: dir, roots: roots, databaseURL: dir.appendingPathComponent("cache/query.sqlite"),
                       files: files, range: start..<start.addingTimeInterval(86400))
    }

    private func line(_ object: [String: Any]) throws -> Data {
        var data = try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
        data.append(10)
        return data
    }

    private func records(source: Int, index: Int) throws -> Data {
        let timestamp = "2026-09-08T10:00:\(String(format: "%02d", index % 60))Z"
        let prompt = "Please implement query snapshot number \(index) and verify the exact token totals."
        let objects: [[String: Any]]
        switch source {
        case 0:
            objects = [
                ["type": "user", "timestamp": timestamp, "message": ["content": prompt]],
                ["type": "assistant", "uuid": "c-\(index)", "timestamp": timestamp,
                 "message": ["id": "c-\(index)", "model": "claude-sonnet-4-6",
                             "usage": ["input_tokens": 100 + index, "output_tokens": 10],
                             "content": [["type": "tool_use", "id": "tool-\(index)", "name": "Read", "input": [:]]]]]
            ]
        case 1:
            objects = [
                ["type": "session_meta", "timestamp": timestamp, "payload": ["id": "codex", "cwd": "/project"]],
                ["type": "turn_context", "timestamp": timestamp, "payload": ["model": "gpt-5.4"]],
                ["type": "event_msg", "timestamp": timestamp, "payload": ["type": "user_message", "message": prompt]],
                ["type": "response_item", "timestamp": timestamp,
                 "payload": ["type": "message", "role": "user", "content": [["type": "input_text", "text": prompt]]]],
                ["type": "event_msg", "timestamp": timestamp,
                 "payload": ["type": "token_count", "info": ["total_token_usage": ["input_tokens": (index + 1) * 100,
                        "output_tokens": (index + 1) * 10, "cached_input_tokens": 0, "reasoning_output_tokens": 0]]]]
            ]
        default:
            objects = [
                ["type": "session", "id": "pi", "timestamp": timestamp, "cwd": "/project"],
                ["type": "session_info", "name": "Query task \(index)", "timestamp": timestamp],
                ["type": "message", "id": "p-user-\(index)", "timestamp": timestamp, "message": ["role": "user", "content": prompt]],
                ["type": "message", "id": "p-\(index)", "timestamp": timestamp,
                 "message": ["role": "assistant", "provider": "anthropic", "model": "claude-sonnet-4-6",
                             "usage": ["input": 100 + index, "output": 10, "cacheRead": 0, "cacheWrite": 0],
                             "content": [["type": "toolCall", "id": "pi-tool-\(index)", "name": "read", "arguments": [:]]]]]
            ]
        }
        return try objects.reduce(into: Data()) { $0.append(try line($1)) }
    }

    private func seed(_ f: Fixture, count: Int = 1) throws {
        for (source, file) in f.files.enumerated() {
            let data = try (0..<count).reduce(into: Data()) { $0.append(try records(source: source, index: $1)) }
            try data.write(to: file)
        }
    }

    private func append(_ data: Data, to file: URL) throws {
        let handle = try FileHandle(forWritingTo: file)
        defer { try? handle.close() }
        try handle.seekToEnd(); try handle.write(contentsOf: data)
    }

    private func assertSame(_ indexed: CoachingScanResult, _ full: CoachingScanResult,
                            file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertEqual(indexed.sessions, full.sessions, file: file, line: line)
        XCTAssertEqual(indexed.prompts, full.prompts, file: file, line: line)
        XCTAssertEqual(indexed.aggregate, full.aggregate, file: file, line: line)
        XCTAssertEqual(indexed.aggregateGroups, full.aggregateGroups, file: file, line: line)
    }

    func testPersistentSnapshotAndFileCacheSurviveReopen() async throws {
        let f = try fixture(); defer { try? FileManager.default.removeItem(at: f.dir) }
        try seed(f, count: 3)
        let cold = await CoachingScan.scan(in: f.range, roots: f.roots, store: f.store)
        XCTAssertEqual(cold.sessions.count, 3)
        XCTAssertGreaterThan(cold.sourceBytesRead, 0)
        let reopened = f.store
        let snapshot = await reopened.snapshot(in: f.range, roots: f.roots)
        assertSame(try XCTUnwrap(snapshot).result, cold)
        let warm = await CoachingScan.scan(in: f.range, roots: f.roots, store: reopened)
        assertSame(warm, cold)
        XCTAssertEqual(warm.cacheHitCount, 3)
        XCTAssertEqual(warm.sourceBytesRead, 0)
        // Snapshot queries use only the saved state, even if source files vanish.
        for file in f.files { try FileManager.default.removeItem(at: file) }
        let stillSaved = await f.store.snapshot(in: f.range, roots: f.roots)
        XCTAssertEqual(stillSaved?.result.sessions.count, 3)
        let refreshed = await CoachingScan.scan(in: f.range, roots: f.roots, store: reopened)
        XCTAssertTrue(refreshed.sessions.isEmpty)
    }

    func testAppendResumesAllProvidersAndMatchesFullReader() async throws {
        let f = try fixture(); defer { try? FileManager.default.removeItem(at: f.dir) }
        try seed(f, count: 4)
        _ = await CoachingScan.scan(in: f.range, roots: f.roots, store: f.store)
        var appended: UInt64 = 0
        for (source, file) in f.files.enumerated() {
            let data = try records(source: source, index: 4)
            appended += UInt64(data.count); try append(data, to: file)
        }
        let incremental = await CoachingScan.scan(in: f.range, roots: f.roots, store: f.store)
        XCTAssertEqual(incremental.resumedFileCount, 3)
        XCTAssertEqual(incremental.sourceBytesRead, appended)
        let full = await CoachingScan.scan(in: f.range, roots: f.roots, forceFullRead: true, store: f.store)
        assertSame(incremental, full)
        XCTAssertEqual(full.cacheHitCount, 0)
        XCTAssertGreaterThan(full.sourceBytesRead, incremental.sourceBytesRead)
    }

    func testIncompleteTailIsReplayedWithoutDoubleCounting() async throws {
        for validTail in [false, true] {
            let f = try fixture(); defer { try? FileManager.default.removeItem(at: f.dir) }
            try seed(f)
            var remainder: [Data] = []
            for (source, file) in f.files.enumerated() {
                let data = try records(source: source, index: 1)
                let cut = validTail ? data.count - 1 : data.count - 9
                try append(data.prefix(cut), to: file)
                remainder.append(data.suffix(from: cut))
            }
            _ = await CoachingScan.scan(in: f.range, roots: f.roots, store: f.store)
            for (i, file) in f.files.enumerated() { try append(remainder[i], to: file) }
            let resumed = await CoachingScan.scan(in: f.range, roots: f.roots, store: f.store)
            XCTAssertEqual(resumed.resumedFileCount, 3)
            let full = await CoachingScan.scan(in: f.range, roots: f.roots, forceFullRead: true, store: f.store)
            assertSame(resumed, full)
        }
    }

    func testReplacementTruncationAndPreservedMtimeInvalidate() async throws {
        let f = try fixture(); defer { try? FileManager.default.removeItem(at: f.dir) }
        try seed(f, count: 3)
        _ = await CoachingScan.scan(in: f.range, roots: f.roots, store: f.store)
        let oldStamp = try XCTUnwrap(LogFileStamp.read(f.files[0]))
        // Same size and mtime, different contents. ctime must invalidate the cache.
        var original = try String(contentsOf: f.files[0], encoding: .utf8)
        original = original.replacingOccurrences(of: "implement", with: "implement".uppercased())
        try Data(original.utf8).write(to: f.files[0])
        try FileManager.default.setAttributes([.modificationDate: oldStamp.modified], ofItemAtPath: f.files[0].path)
        try records(source: 1, index: 9).write(to: f.files[1]) // truncate
        try records(source: 2, index: 9).write(to: f.files[2], options: .atomic) // replace inode
        let rebuilt = await CoachingScan.scan(in: f.range, roots: f.roots, store: f.store)
        XCTAssertEqual(rebuilt.cacheHitCount, 0)
        XCTAssertEqual(rebuilt.resumedFileCount, 0)
        let full = await CoachingScan.scan(in: f.range, roots: f.roots, forceFullRead: true, store: f.store)
        assertSame(rebuilt, full)
    }

    func testScopeAndRootIsolationAndSavedScopeSwitch() async throws {
        let f = try fixture(); defer { try? FileManager.default.removeItem(at: f.dir) }
        try seed(f)
        let store = f.store
        _ = await CoachingScan.scan(in: f.range, roots: f.roots, store: store)
        let previousDay = f.range.lowerBound.addingTimeInterval(-86400)..<f.range.lowerBound
        let before = await store.snapshot(in: previousDay, roots: f.roots)
        XCTAssertNil(before)
        let empty = await CoachingScan.scan(in: previousDay, roots: f.roots, store: store)
        XCTAssertTrue(empty.sessions.isEmpty)
        XCTAssertEqual(empty.sourceBytesRead, 0)
        let currentAgain = await store.snapshot(in: f.range, roots: f.roots)
        XCTAssertEqual(currentAgain?.result.sessions.count, 3)
        let otherRoots = AgentLogRoots(home: f.dir.appendingPathComponent("other").path, environment: [:])
        let other = await store.snapshot(in: f.range, roots: otherRoots)
        XCTAssertNil(other)
    }

    func testUnavailableDatabaseFallsBackToSources() async throws {
        let f = try fixture(); defer { try? FileManager.default.removeItem(at: f.dir) }
        try seed(f)
        let invalid = CoachingQueryStore(url: f.files[0].appendingPathComponent("impossible.sqlite"))
        let result = await CoachingScan.scan(in: f.range, roots: f.roots, store: invalid)
        XCTAssertEqual(result.sessions.count, 3)
        XCTAssertEqual(result.cacheHitCount, 0)
        let full = await CoachingScan.scan(in: f.range, roots: f.roots, forceFullRead: true, store: f.store)
        assertSame(result, full)
    }

    func testCorruptCheckpointFallsBackToFullParse() async throws {
        let f = try fixture(); defer { try? FileManager.default.removeItem(at: f.dir) }
        try seed(f, count: 2)
        let store = f.store
        let first = await CoachingScan.scan(in: f.range, roots: f.roots, store: store)
        for (index, file) in f.files.enumerated() {
            let source: SessionSource = [.cli, .codex, .piagent][index]
            let scannedFile = try XCTUnwrap(first.sessions.first { $0.source == source }?.fileURL)
            let key = CoachingQueryStore.fileKey(scannedFile, source: source, range: f.range)
            let value = await store.file(key)
            let old = try XCTUnwrap(value, "missing source \(source.rawValue) at \(file.path)")
            let checkpoint = try XCTUnwrap(old.checkpoint)
            let corrupt = LogCheckpoint(offset: checkpoint.offset, state: Data("broken".utf8),
                                        headHash: checkpoint.headHash, boundaryHash: checkpoint.boundaryHash)
            await store.saveFile(CachedLogFile(stamp: old.stamp, result: old.result, checkpoint: corrupt), key: key)
            try append(records(source: index, index: 2), to: file)
        }
        let rebuilt = await CoachingScan.scan(in: f.range, roots: f.roots, store: store)
        XCTAssertEqual(rebuilt.resumedFileCount, 0)
        let full = await CoachingScan.scan(in: f.range, roots: f.roots, forceFullRead: true, store: store)
        assertSame(rebuilt, full)
    }

    func testCancelledScanDoesNotPublishSnapshot() async throws {
        let f = try fixture(); defer { try? FileManager.default.removeItem(at: f.dir) }
        try seed(f)
        let store = f.store
        let worker = Task {
            await CoachingScan.scan(in: f.range, roots: f.roots, store: store, progress: { done, _ in
                if done == 0 { withUnsafeCurrentTask { $0?.cancel() } }
            })
        }
        _ = await worker.value
        let saved = await store.snapshot(in: f.range, roots: f.roots)
        XCTAssertNil(saved)
    }

    func testOlderScanCannotOverwriteNewerSnapshot() async throws {
        let f = try fixture(); defer { try? FileManager.default.removeItem(at: f.dir) }
        let store = f.store
        let old = await store.beginScan(in: f.range, roots: f.roots)
        let new = await store.beginScan(in: f.range, roots: f.roots)
        let result = CoachingScanResult(prompts: [], sessions: [], candidateFileCount: 0, sourceFiles: [], sourceRoots: [])
        await store.saveSnapshot(result, range: f.range, roots: f.roots, generation: old)
        let stale = await store.snapshot(in: f.range, roots: f.roots)
        XCTAssertNil(stale)
        await store.saveSnapshot(result, range: f.range, roots: f.roots, generation: new)
        let current = await store.snapshot(in: f.range, roots: f.roots)
        XCTAssertNotNil(current)
    }

    func testCodexBaselineAndResetAcrossAppendStayExact() async throws {
        let f = try fixture(); defer { try? FileManager.default.removeItem(at: f.dir) }
        let initial = """
        {"type":"session_meta","timestamp":"2026-09-07T23:00:00Z","payload":{"id":"reset","model_provider":"openai"}}
        {"type":"turn_context","timestamp":"2026-09-07T23:00:00Z","payload":{"model":"gpt-5.4"}}
        {"type":"event_msg","timestamp":"2026-09-07T23:59:00Z","payload":{"type":"token_count","info":{"total_token_usage":{"input_tokens":100,"output_tokens":20}}}}
        {"type":"event_msg","timestamp":"2026-09-08T00:01:00Z","payload":{"type":"token_count","info":{"total_token_usage":{"input_tokens":150,"output_tokens":30}}}}
        """ + "\n"
        try Data(initial.utf8).write(to: f.files[1])
        let store = f.store
        _ = await CoachingScan.scan(in: f.range, roots: f.roots, store: store)
        let suffix = """
        {"type":"event_msg","timestamp":"2026-09-08T00:02:00Z","payload":{"type":"token_count","info":{"total_token_usage":{"input_tokens":20,"output_tokens":3}}}}
        """ + "\n"
        try append(Data(suffix.utf8), to: f.files[1])
        let resumed = await CoachingScan.scan(in: f.range, roots: f.roots, store: store)
        XCTAssertEqual(resumed.resumedFileCount, 1)
        XCTAssertEqual(resumed.sessions.first?.totalTokens, 60)
        XCTAssertEqual(resumed.sessions.first?.usageScope, .partialRange)
        let full = await CoachingScan.scan(in: f.range, roots: f.roots, forceFullRead: true, store: store)
        assertSame(resumed, full)
    }

    func testQueryTimingsOnSyntheticHistory() async throws {
        let f = try fixture(); defer { try? FileManager.default.removeItem(at: f.dir) }
        try seed(f, count: 40)
        // Historical tool payloads model why avoiding source re-reads matters.
        let payload = try line(["type": "ignored", "timestamp": "2026-09-08T10:05:00Z",
                                "payload": String(repeating: "x", count: 256 * 1024)])
        for file in f.files { try append(payload, to: file) }
        for n in 0..<20 {
            try FileManager.default.copyItem(at: f.files[0], to: f.files[0].deletingLastPathComponent().appendingPathComponent("copy-\(n).jsonl"))
        }
        let start = Date()
        let cold = await CoachingScan.scan(in: f.range, roots: f.roots, store: f.store)
        let coldMs = Date().timeIntervalSince(start) * 1000
        let freshStore = f.store
        let diskStart = Date()
        let saved = await freshStore.snapshot(in: f.range, roots: f.roots)
        let diskMs = Date().timeIntervalSince(diskStart) * 1000
        let ramStart = Date()
        _ = await freshStore.snapshot(in: f.range, roots: f.roots)
        let ramMs = Date().timeIntervalSince(ramStart) * 1000
        let warmStart = Date()
        let warm = await CoachingScan.scan(in: f.range, roots: f.roots, store: freshStore)
        let warmMs = Date().timeIntervalSince(warmStart) * 1000
        assertSame(try XCTUnwrap(saved).result, cold)
        assertSame(warm, cold)
        XCTAssertEqual(warm.sourceBytesRead, 0)
        print(String(format: "QUERY_BENCH files=%d bytes=%llu cold_ms=%.2f snapshot_disk_ms=%.2f snapshot_ram_ms=%.2f refresh_warm_ms=%.2f",
                     cold.candidateFileCount, cold.sourceBytesRead, coldMs, diskMs, ramMs, warmMs))
    }
}
