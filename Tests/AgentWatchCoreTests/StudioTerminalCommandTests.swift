import XCTest
@testable import AgentWatchCore

final class StudioTerminalCommandTests: XCTestCase {
    private func root() throws -> URL {
        let base = realpath(FileManager.default.temporaryDirectory.path, nil)!
        defer { free(base) }
        let url = URL(fileURLWithPath: String(cString: base)).appendingPathComponent("studio-terminal-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: url) }
        return url
    }
    private func profile(_ root: URL) throws -> StudioCLIProfile {
        try StudioCLIProfiles.prepare(connection: StudioProfile(origin: StudioOrigin("https://studio.example"), id: String(repeating: "a", count: 64)), provider: .claude, directory: root.appendingPathComponent("profiles"))
    }
    func testTerminalScriptPreservesLiteralArgumentsAndRemovesItself() throws {
        let root = try root(), profile = try profile(root)
        let project = root.appendingPathComponent("project ' ; $(touch forbidden) `literal`\nline")
        try FileManager.default.createDirectory(at: project, withIntermediateDirectories: true)
        let helper = root.appendingPathComponent("helper ' `literal`"), captured = root.appendingPathComponent("captured")
        let body = "#!/bin/sh\n/usr/bin/printf '%s\\0' \"$@\" > \(StudioTerminalCommand.quote(captured.path))\n"
        try Data(body.utf8).write(to: helper)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: helper.path)
        let executable = try StudioCLIExecutable.resolve(.claude, explicit: helper)
        let model = StudioModel(id: "model'\"$(touch forbidden);", displayName: "Fixture", ownedBy: "claude", nativeProtocol: "messages")
        let session = UUID()
        let plan = try StudioCLILaunchPlan(executable: executable, profile: profile, project: project, model: model, resumeID: session)
        let command = try StudioTerminalCommand.create(plan: plan, helper: helper, directory: root.appendingPathComponent("launches"))
        XCTAssertEqual(try FileManager.default.attributesOfItem(atPath: command.url.path)[.posixPermissions] as? Int, 0o700)
        let script = try String(contentsOf: command.url, encoding: .utf8)
        XCTAssertFalse(script.contains("ANTHROPIC_API_KEY")); XCTAssertFalse(script.contains("AGENTWATCH_STUDIO_KEY"))
        let process = Process(); process.executableURL = URL(fileURLWithPath: "/bin/sh"); process.arguments = [command.url.path]
        process.currentDirectoryURL = root; process.environment = ["PATH": "/usr/bin:/bin"]
        try process.run(); process.waitUntilExit()
        XCTAssertEqual(process.terminationStatus, 0)
        let args = String(decoding: try Data(contentsOf: captured), as: UTF8.self).split(separator: "\u{0}").map(String.init)
        XCTAssertEqual(args, ["run", "claude", "--profile", profile.connection.id, "--model", model.id, "--project", plan.project.path, "--binary", executable.url.path, "--resume", session.uuidString.lowercased()])
        XCTAssertFalse(FileManager.default.fileExists(atPath: command.url.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: root.appendingPathComponent("forbidden").path))
    }
    func testOldTerminalCommandCannotSelectDifferentActiveIdentity() throws {
        let first = try StudioProfile(origin: StudioOrigin("https://studio.example"), id: String(repeating: "a", count: 64))
        let second = try StudioProfile(origin: StudioOrigin("https://other.example"), id: String(repeating: "b", count: 64))
        XCTAssertNoThrow(try StudioTerminalCommand.validateProfile(first, expectedID: first.id))
        XCTAssertNoThrow(try StudioTerminalCommand.validateProfile(second, expectedID: nil))
        XCTAssertThrowsError(try StudioTerminalCommand.validateProfile(second, expectedID: first.id)) { XCTAssertEqual($0 as? StudioError, .identityChanged) }
    }
    func testMissingHelperAndRedirectedLaunchDirectoryAreRefused() throws {
        let root = try root(), profile = try profile(root)
        let helper = URL(fileURLWithPath: "/usr/bin/true")
        let plan = try StudioCLILaunchPlan(executable: StudioCLIExecutable.resolve(.claude, explicit: helper), profile: profile, project: root, model: StudioModel(id: "model", displayName: "Fixture", ownedBy: "claude", nativeProtocol: "messages"))
        XCTAssertThrowsError(try StudioTerminalCommand.create(plan: plan, helper: root.appendingPathComponent("missing"), directory: root)) { XCTAssertEqual($0 as? StudioCLIError, .helperMissing) }
        let link = root.appendingPathComponent("link")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: profile.home)
        XCTAssertThrowsError(try StudioTerminalCommand.create(plan: plan, helper: helper, directory: link)) { XCTAssertEqual($0 as? StudioCLIError, .unsafePath) }
        let command = try StudioTerminalCommand.create(plan: plan, helper: helper, directory: root.appendingPathComponent("launches"))
        command.discard(); XCTAssertFalse(FileManager.default.fileExists(atPath: command.url.path))
    }
}
