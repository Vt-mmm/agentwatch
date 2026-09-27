import XCTest
@testable import AgentWatchCore

private actor SuspendedLocalReader: StudioLocalLogReading {
    var continuation: CheckedContinuation<StudioLocalLogSnapshot, Never>?
    func read(connection: StudioProfile, range: Range<Date>) async -> StudioLocalLogSnapshot {
        await withCheckedContinuation { continuation = $0 }
    }
    func waiting() -> Bool { continuation != nil }
    func finish(_ value: StudioLocalLogSnapshot) { continuation?.resume(returning: value); continuation = nil }
}

final class StudioLocalLogTests: XCTestCase, @unchecked Sendable {
    private let range = Date(timeIntervalSince1970: 1788220800)..<Date(timeIntervalSince1970: 1790812800)
    private func root() throws -> URL {
        let base = realpath(FileManager.default.temporaryDirectory.path, nil)!
        defer { free(base) }
        let root = URL(fileURLWithPath: String(cString: base)).appendingPathComponent("studio-logs-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        return root
    }
    private func identity(_ letter: String = "a") throws -> StudioProfile {
        try StudioProfile(origin: StudioOrigin("https://studio.example"), id: String(repeating: letter, count: 64))
    }
    private func write(_ text: String, _ file: URL) throws {
        try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(text.utf8).write(to: file)
    }
    private func claude(_ count: Int = 10, id: String = "request-fixture") -> String {
        """
        {"type":"user","timestamp":"2026-09-28T01:00:00Z","message":{"content":"PRIVATE_FIXTURE_PROMPT"}}
        {"type":"assistant","timestamp":"2026-09-28T01:00:01Z","message":{"id":"\(id)","model":"claude-fixture","usage":{"input_tokens":\(count),"output_tokens":5},"content":[{"type":"text","text":"PRIVATE_FIXTURE_OUTPUT"}]}}

        """
    }
    private let codex = """
    {"type":"session_meta","timestamp":"2026-09-28T01:00:00Z","payload":{"id":"same-session","cwd":"/fixture/project","model_provider":"agent_studio"}}
    {"type":"turn_context","timestamp":"2026-09-28T01:00:00Z","payload":{"model":"gpt-fixture"}}
    {"type":"event_msg","timestamp":"2026-09-28T01:00:01Z","payload":{"type":"token_count","info":{"total_token_usage":{"input_tokens":100,"output_tokens":20,"cached_input_tokens":50,"reasoning_output_tokens":5}}}}

    """
    func testRegistryUsesSelectedIdentityAndFindsNestedLogsWithoutEnvironment() throws {
        let root = try root(), connection = try identity(), directory = root.appendingPathComponent("profiles")
        let first = try StudioCLIProfiles.prepare(connection: connection, provider: .claude, directory: directory)
        let other = try StudioCLIProfiles.prepare(connection: identity("b"), provider: .claude, directory: directory)
        try write(claude(), first.logRoot.appendingPathComponent("project/session.jsonl"))
        try write(claude(2, id: "child"), first.logRoot.appendingPathComponent("project/session/subagents/child.jsonl"))
        try write(claude(9000), other.logRoot.appendingPathComponent("project/session.jsonl"))
        // A personal source is deliberately outside the registered profile tree.
        let personal = root.appendingPathComponent(".claude/projects/project/personal.jsonl")
        try write(claude(8000), personal)
        let prior = try Data(contentsOf: personal)
        let snapshot = StudioLocalLogReader.scan(connection: connection, range: range, directory: directory)
        XCTAssertEqual(snapshot.sessions.count, 2); XCTAssertEqual(snapshot.filesRead, 2)
        XCTAssertEqual(Set(snapshot.sessions.compactMap(\.knownTokens)), [15, 7])
        XCTAssertTrue(snapshot.sessions.allSatisfy { $0.profileID == connection.id && !$0.partial })
        XCTAssertEqual(try Data(contentsOf: personal), prior)
        XCTAssertEqual(snapshot.registrations.filter { $0.profile != nil }.count, 1)
        XCTAssertFalse(String(describing: snapshot).contains("PRIVATE_FIXTURE_PROMPT"))
        XCTAssertFalse(String(describing: snapshot).contains("PRIVATE_FIXTURE_OUTPUT"))
        let second = StudioLocalLogReader.scan(connection: try identity("b"), range: range, directory: directory)
        XCTAssertEqual(second.sessions.map(\.knownTokens), [9005])
        XCTAssertNotEqual(snapshot.sessions.first { $0.sessionID == "session" }?.id, second.sessions.first?.id)
    }
    func testActiveArchivedAndHardlinkedCopiesDoNotDoubleCountCodex() throws {
        let root = try root(), connection = try identity()
        let profile = try StudioCLIProfiles.prepare(connection: connection, provider: .codex, directory: root)
        let live = profile.logRoot.appendingPathComponent("2026/09/28/rollout.jsonl")
        let archive = profile.config.appendingPathComponent("archived_sessions/copy.jsonl")
        try write(codex, live); try write(codex, archive)
        try FileManager.default.linkItem(at: live, to: archive.deletingLastPathComponent().appendingPathComponent("hardlink.jsonl"))
        let snapshot = StudioLocalLogReader.scan(connection: connection, range: range, directory: root)
        XCTAssertEqual(snapshot.filesRead, 2); XCTAssertEqual(snapshot.sessions.count, 1)
        XCTAssertEqual(snapshot.sessions.first?.knownTokens, 120)
        XCTAssertEqual(snapshot.sessions.first?.summary.cacheReadTokens, 50)
        XCTAssertEqual(snapshot.sessions.first?.summary.reasoningTokens, 5)
        XCTAssertFalse(snapshot.partial)
    }
    func testInvalidManifestAndSymlinksNeverRedirectScan() throws {
        let root = try root(), connection = try identity()
        let profile = try StudioCLIProfiles.prepare(connection: connection, provider: .claude, directory: root)
        let outside = root.appendingPathComponent("outside"), marker = outside.appendingPathComponent("secret.jsonl")
        try write(claude(9000), marker)
        try FileManager.default.createSymbolicLink(at: profile.logRoot, withDestinationURL: outside)
        let blocked = StudioLocalLogReader.scan(connection: connection, range: range, directory: root)
        XCTAssertTrue(blocked.sessions.isEmpty); XCTAssertTrue(blocked.issues.contains(.unsafePath))
        try FileManager.default.removeItem(at: profile.logRoot)
        try write(claude(), profile.logRoot.appendingPathComponent("project/good.jsonl"))
        try FileManager.default.createSymbolicLink(at: profile.logRoot.appendingPathComponent("external"), withDestinationURL: outside)
        let mixed = StudioLocalLogReader.scan(connection: connection, range: range, directory: root)
        XCTAssertEqual(mixed.sessions.map(\.knownTokens), [15]); XCTAssertTrue(mixed.issues.contains(.unsafePath))
        let manifest = profile.root.appendingPathComponent("profile.json")
        var value = try JSONSerialization.jsonObject(with: Data(contentsOf: manifest)) as! [String: Any]
        value["root"] = outside.absoluteString
        try JSONSerialization.data(withJSONObject: value).write(to: manifest)
        let invalid = StudioLocalLogReader.scan(connection: connection, range: range, directory: root)
        XCTAssertTrue(invalid.sessions.isEmpty); XCTAssertTrue(invalid.issues.contains(.invalidProfile))
        XCTAssertEqual(try String(contentsOf: marker, encoding: .utf8), claude(9000))
    }
    func testUnknownMalformedAndLimitedReadsAreNeverCompleteZero() throws {
        let root = try root(), connection = try identity()
        let first = try StudioCLIProfiles.prepare(connection: connection, provider: .claude, directory: root)
        try write("{\"type\":\"user\",\"timestamp\":\"2026-09-28T01:00:00Z\",\"message\":{\"content\":\"fixture\"}}\n", first.logRoot.appendingPathComponent("project/no-usage.jsonl"))
        let second = try StudioCLIProfiles.prepare(connection: connection, provider: .codex, directory: root)
        try write("malformed\n", second.logRoot.appendingPathComponent("bad.jsonl"))
        let snapshot = StudioLocalLogReader.scan(connection: connection, range: range, directory: root)
        XCTAssertEqual(snapshot.sessions.count, 1); XCTAssertNil(snapshot.sessions.first?.knownTokens)
        XCTAssertTrue(snapshot.partial); XCTAssertTrue(snapshot.issues.contains(.unreadable))
        for limits in [(0, 100_000), (100, 1)] {
            let limited = StudioLocalLogReader.scan(connection: connection, range: range, directory: root, maxFiles: limits.0, maxBytes: limits.1)
            XCTAssertTrue(limited.sessions.isEmpty); XCTAssertTrue(limited.partial); XCTAssertTrue(limited.issues.contains(.limitReached))
        }
    }
    func testBoundedReaderDoesNotChaseAppendedBytes() throws {
        let root = try root(), file = root.appendingPathComponent("growing.jsonl")
        try write("first\n", file)
        var lines: [String] = []
        JsonlLineReader.forEachLineData(at: file, maxBytes: 6) { data in
            lines.append(String(decoding: data, as: UTF8.self))
            let handle = try! FileHandle(forWritingTo: file)
            try! handle.seekToEnd(); try! handle.write(contentsOf: Data("second\n".utf8)); try! handle.close()
        }
        XCTAssertEqual(lines, ["first"])
    }
    func testCleanCopyCannotHidePartialEvidenceFromAnotherCopy() throws {
        let root = try root(), connection = try identity()
        let profile = try StudioCLIProfiles.prepare(connection: connection, provider: .claude, directory: root)
        try write(claude(), profile.logRoot.appendingPathComponent("a/session.jsonl"))
        try write(claude() + "malformed\n", profile.logRoot.appendingPathComponent("z/session.jsonl"))
        let snapshot = StudioLocalLogReader.scan(connection: connection, range: range, directory: root)
        XCTAssertEqual(snapshot.sessions.count, 1); XCTAssertEqual(snapshot.sessions.first?.knownTokens, 15)
        XCTAssertTrue(snapshot.sessions.first?.partial == true); XCTAssertTrue(snapshot.partial)
    }
    @MainActor func testClearedStoreRejectsLatePreviousProfileResult() async throws {
        let root = try root(), connection = try identity(), reader = SuspendedLocalReader()
        let value = StudioLocalLogReader.scan(connection: connection, range: range, directory: root)
        let store = StudioLocalLogStore(reader: reader), range = range
        let task = Task { await store.refresh(connection: connection, range: range) }
        for _ in 0..<100 { if await reader.waiting() { break }; try await Task.sleep(for: .milliseconds(10)) }
        XCTAssertTrue(store.loading)
        store.clear(); await reader.finish(value); await task.value
        XCTAssertNil(store.snapshot); XCTAssertFalse(store.loading)
    }
}
