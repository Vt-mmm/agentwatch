import XCTest
@testable import AgentWatchCore

final class StudioRuntimeBindingTests: XCTestCase {
    private func fixture() throws -> URL {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("runtime-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        return root
    }
    private func executable(_ root: URL, _ name: String, _ content: String) throws -> URL {
        let path = root.appendingPathComponent(name)
        try Data(content.utf8).write(to: path)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: path.path)
        return path
    }

    func testSkipsBrokenNodeAndNeverUsesLaunchPATHForJS() throws {
        let root = try fixture()
        let bad = try executable(root, "broken-node", "#!/bin/sh\nexit 1\n")
        let node = URL(fileURLWithPath: "/usr/local/bin/node")
        guard FileManager.default.isExecutableFile(atPath: node.path) else { throw XCTSkip("Working Node fixture unavailable") }
        let js = try executable(root, "cli.js", "#!/usr/bin/env node\nconsole.log(process.execPath);\n")
        let binding = try StudioRuntimeBinding.resolve(entrypoint: js, nodeCandidates: [bad, node])
        XCTAssertEqual(binding.interpreter, node.resolvingSymlinksInPath())
        let process = Process(), output = Pipe()
        process.executableURL = binding.executable; process.arguments = binding.prefixArguments
        process.environment = ["PATH": root.path]
        process.standardOutput = output; process.standardError = FileHandle.nullDevice
        try process.run(); process.waitUntilExit()
        XCTAssertEqual(process.terminationStatus, 0)
        XCTAssertEqual(String(decoding: output.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines), binding.interpreter?.path)
    }

    func testExplicitBrokenNodeDoesNotFallBack() throws {
        let root = try fixture()
        let bad = try executable(root, "broken-node", "#!/bin/sh\nexit 1\n")
        let js = try executable(root, "cli.js", "#!/usr/bin/env node\n")
        XCTAssertThrowsError(try StudioRuntimeBinding.resolve(entrypoint: js, node: bad)) { XCTAssertEqual($0 as? StudioCLIError, .runtimeMissing) }
    }

    func testNativeScriptIsNotForcedThroughNodeAndChangesInvalidateBinding() throws {
        let root = try fixture()
        let script = try executable(root, "cli", "#!/bin/sh\necho fixture\n")
        let binding = try StudioRuntimeBinding.resolve(entrypoint: script)
        XCTAssertNil(binding.interpreter); XCTAssertEqual(binding.prefixArguments, [])
        try binding.validate()
        try Data("#!/bin/sh\necho replaced\n".utf8).write(to: script)
        XCTAssertThrowsError(try binding.validate()) { XCTAssertEqual($0 as? StudioCLIError, .runtimeChanged) }
    }

    func testShebangOptionsAreNotSilentlyDiscarded() throws {
        let script = try executable(fixture(), "cli", "#!/usr/bin/env -S node --experimental-permission\n")
        XCTAssertThrowsError(try StudioRuntimeBinding.resolve(entrypoint: script)) { XCTAssertEqual($0 as? StudioCLIError, .unsupportedVersion) }
    }
}
