import XCTest
@testable import AgentWatchCore

final class StudioVersionQualificationTests: XCTestCase {
    func testBulkVersionProbeRejectsUnknownVersionsWithoutSupplyingCredentials() async throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let bin = dir.appendingPathComponent("fixture-cli")
        let script = """
        #!/bin/sh
        test "$1" = '--version' || exit 7
        test -z "$ANTHROPIC_API_KEY$ANTHROPIC_AUTH_TOKEN$OPENAI_API_KEY$STUDIO_API_KEY" || exit 8
        printf '%s\\n' 'codex-cli 0.155.1'
        """
        try Data(script.utf8).write(to: bin)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: bin.path)
        try await StudioCLIPreflight.verifyVersion(StudioCLIExecutable(url: bin, provider: .codex))
        try Data(script.replacingOccurrences(of: "0.155.1", with: "0.1.0").utf8).write(to: bin)
        do {
            try await StudioCLIPreflight.verifyVersion(StudioCLIExecutable(url: bin, provider: .codex))
            XCTFail("unknown CLI schema must not receive bulk configuration")
        } catch { XCTAssertEqual(error as? StudioCLIError, .unsupportedVersion) }
    }
}
