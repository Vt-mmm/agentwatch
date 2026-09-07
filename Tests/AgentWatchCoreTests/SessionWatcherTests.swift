// Tests SessionWatcher's refresh logic (no polling — synchronous refreshNow).
// Isolated fake project store; never write to the operator's Claude logs.

import XCTest
@testable import AgentWatchCore

final class SessionWatcherTests: XCTestCase {

    private var projectsRoot: URL!
    private var slug: String!
    private var sessionURL: URL!
    private var fakeCwd: URL!

    override func setUp() async throws {
        projectsRoot = FileManager.default.temporaryDirectory.appendingPathComponent("watcher-" + UUID().uuidString)
        let stamp = UUID().uuidString.prefix(8)
        let pathString = "/tmp/cw-watcher-test-\(stamp)"
        fakeCwd = URL(fileURLWithPath: pathString)
        slug = ProjectPath.slug(for: fakeCwd)
        let dir = projectsRoot.appendingPathComponent(slug, isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        sessionURL = dir.appendingPathComponent("test-session.jsonl")
        try "".write(to: sessionURL, atomically: true, encoding: .utf8)
    }

    override func tearDown() async throws {
        if let projectsRoot { try? FileManager.default.removeItem(at: projectsRoot) }
    }

    private func append(_ line: [String: Any]) throws {
        let json = try JSONSerialization.data(withJSONObject: line)
        let payload = String(data: json, encoding: .utf8)! + "\n"
        let handle = try FileHandle(forWritingTo: sessionURL)
        try handle.seekToEnd()
        try handle.write(contentsOf: payload.data(using: .utf8)!)
        try handle.close()
    }

    @MainActor
    func testRefreshReflectsAppendedTokens() async throws {
        let w = SessionWatcher(projectsRoot: projectsRoot)
        w.startPinned(folder: fakeCwd, intervalSeconds: 10)  // long interval; we drive manually
        defer { w.stop() }

        try append([
            "type": "assistant",
            "timestamp": "2026-06-12T05:00:00.000Z",
            "message": [
                "model": "claude-sonnet-4-6",
                "usage": ["input_tokens": 100, "output_tokens": 50],
                "content": [],
            ],
        ])
        // mtime resolution on APFS is sub-second but APIs report seconds-level —
        // bump it explicitly so refreshNow sees a change.
        try FileManager.default.setAttributes(
            [.modificationDate: Date()], ofItemAtPath: sessionURL.path
        )

        let s1 = w.refreshNow()
        XCTAssertEqual(s1?.inputTokens, 100)
        XCTAssertEqual(s1?.outputTokens, 50)
        XCTAssertEqual(s1?.modelFamily, .sonnet)

        try await Task.sleep(nanoseconds: 1_100_000_000)  // ensure mtime advances
        try append([
            "type": "assistant",
            "timestamp": "2026-06-12T05:00:10.000Z",
            "message": [
                "model": "claude-sonnet-4-6",
                "usage": ["input_tokens": 20, "output_tokens": 5],
                "content": [],
            ],
        ])
        try FileManager.default.setAttributes(
            [.modificationDate: Date()], ofItemAtPath: sessionURL.path
        )

        let s2 = w.refreshNow()
        XCTAssertEqual(s2?.inputTokens, 120)
        XCTAssertEqual(s2?.outputTokens, 55)
    }

    @MainActor
    func testStopHaltsBackgroundPolling() async throws {
        let w = SessionWatcher(projectsRoot: projectsRoot)
        w.startPinned(folder: fakeCwd, intervalSeconds: 0.2)
        XCTAssertTrue(w.isWatching)
        w.stop()
        XCTAssertFalse(w.isWatching)
    }
}
