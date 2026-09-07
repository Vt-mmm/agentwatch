import XCTest
@testable import AgentWatchCore

final class LogReadingTests: XCTestCase {
    func testReaderPreservesLongRecordsUTF8ChunkBoundariesAndUnterminatedTail() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let lines = [String(repeating: "a", count: 262_143) + "ế", String(repeating: "b", count: 8_000_000), "cuối cùng"]
        try ("\n" + lines.joined(separator: "\n\n") ).write(to: root, atomically: true, encoding: .utf8)
        var output: [String] = []
        JsonlLineReader.forEachLineData(at: root) { output.append(String(decoding: $0, as: UTF8.self)) }
        XCTAssertEqual(output, lines)
    }
    func testCodexTimestampFormatsPreserveRangeBoundaries() throws {
        let file = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: file) }
        let dates = ["2026-09-07T08:00:00+07:00", "2026-09-07T01:00:00Z", "2026-09-07T01:00:00.999Z", "2026-09-07T01:00:01.000Z"]
        let records = dates.map { ["type": "event_msg", "timestamp": $0, "payload": ["type": "agent_message", "message": "synthetic"]] as [String: Any] }
        try records.reduce(into: Data()) { data, record in
            data.append(try JSONSerialization.data(withJSONObject: record)); data.append(10)
        }.write(to: file)
        let start = ISO8601DateFormatter().date(from: "2026-09-07T01:00:00Z")!
        let summary = try XCTUnwrap(CodexJsonlParser.summarize(file: file, range: start..<start.addingTimeInterval(1)))
        XCTAssertEqual(summary.firstTimestamp, start)
        XCTAssertEqual(try XCTUnwrap(summary.lastTimestamp).timeIntervalSince(start), 0.999, accuracy: 0.00001)
    }
    func testExecutableDiscoveryRejectsMissingAndDirectories() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let executable = root.appendingPathComponent("codex")
        try Data("#!/bin/sh\nexit 0\n".utf8).write(to: executable)
        XCTAssertNil(CodexQuotaClient.installedExecutable(candidates: [root, executable]))
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: executable.path)
        XCTAssertEqual(CodexQuotaClient.installedExecutable(candidates: [root, executable]), executable)
        let link = root.appendingPathComponent("codex-link")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: executable)
        XCTAssertEqual(CodexQuotaClient.installedExecutable(candidates: [link]), link)
    }
}
