import XCTest
@testable import AgentWatchCore

/// Members install Node, Pi and Piagent in different ways (installer,
/// Homebrew, nvm, fnm, Volta, a custom npm prefix). Watch must find them the
/// same way on every Mac.
final class StudioInstallLocationsTests: XCTestCase {
    private func home() throws -> URL {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("install-locations-" + UUID().uuidString).resolvingSymlinksInPath()
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        return root
    }
    private func write(_ file: URL, _ text: String, executable: Bool = false) throws {
        try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(text.utf8).write(to: file)
        if executable { try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: file.path) }
    }
    private func link(_ bin: URL, to target: String) throws {
        try FileManager.default.createDirectory(at: bin.deletingLastPathComponent(), withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(atPath: bin.path, withDestinationPath: target)
    }
    /// `npm install -g @piagent/platform` into a prefix.
    @discardableResult private func piagent(_ prefix: URL, version: String = "1.9.0") throws -> URL {
        let root = prefix.appendingPathComponent("lib/node_modules/@piagent/platform")
        try write(root.appendingPathComponent("package.json"), #"{"name":"@piagent/platform","version":"\#(version)"}"#)
        try write(root.appendingPathComponent("scripts/piagent-studio.mjs"), "#!/usr/bin/env node\n", executable: true)
        try link(prefix.appendingPathComponent("bin/piagent"), to: "../lib/node_modules/@piagent/platform/scripts/piagent-cli.mjs")
        return root
    }
    /// `npm install -g @earendil-works/pi-coding-agent` into a prefix.
    @discardableResult private func pi(_ prefix: URL, version: String = "0.87.1") throws -> URL {
        let root = prefix.appendingPathComponent("lib/node_modules/@earendil-works/pi-coding-agent")
        try write(root.appendingPathComponent("package.json"), #"{"name":"@earendil-works/pi-coding-agent","version":"\#(version)"}"#)
        try write(root.appendingPathComponent("dist/bundle/cli.js"), "#!/usr/bin/env node\n", executable: true)
        try link(prefix.appendingPathComponent("bin/pi"), to: "../lib/node_modules/@earendil-works/pi-coding-agent/dist/bundle/cli.js")
        return root
    }

    func testVersionManagedNodeInstallsAreFoundNewestFirst() throws {
        let home = try home()
        for version in ["v20.11.0", "v24.1.0", "v22.19.0", "v24.11.1"] {
            try FileManager.default.createDirectory(at: home.appendingPathComponent(".nvm/versions/node/" + version), withIntermediateDirectories: true)
        }
        try FileManager.default.createDirectory(at: home.appendingPathComponent("Library/Application Support/fnm/node-versions/v24.2.0/installation"), withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: home.appendingPathComponent(".volta/tools/image/node/22.20.0"), withIntermediateDirectories: true)
        let relative = StudioInstallLocations.versionManagedPrefixes(home: home).map { String($0.path.dropFirst(home.path.count + 1)) }
        XCTAssertEqual(relative, [".nvm/versions/node/v24.11.1", ".nvm/versions/node/v24.1.0", ".nvm/versions/node/v22.19.0", ".nvm/versions/node/v20.11.0",
                                  "Library/Application Support/fnm/node-versions/v24.2.0/installation", ".volta/tools/image/node/22.20.0"])
        let nodes = StudioRuntimeBinding.defaultNodeCandidates(home: home).map(\.path)
        XCTAssertEqual(Array(nodes.prefix(4)), ["/usr/local/bin/node", "/opt/homebrew/bin/node", "/opt/homebrew/opt/node@22/bin/node", "/usr/local/opt/node@22/bin/node"])
        XCTAssertEqual(nodes[4], home.appendingPathComponent(".nvm/versions/node/v24.11.1/bin/node").path)
    }

    func testPiagentAndPiInstalledWithNvmOrVoltaAreFound() throws {
        let home = try home()
        XCTAssertThrowsError(try StudioManagedConfiguration.runtimeRoot(home: home, system: []))
        let nvm = home.appendingPathComponent(".nvm/versions/node/v24.11.1")
        let root = try piagent(nvm); try pi(nvm)
        XCTAssertEqual(try StudioManagedConfiguration.runtimeRoot(home: home, system: []), root.resolvingSymlinksInPath())
        XCTAssertEqual(try StudioClientConfiguration.piExecutable(home: home, system: []), nvm.appendingPathComponent("bin/pi"))
        // Volta keeps each global package in its own image.
        let volta = try self.home()
        let image = volta.appendingPathComponent(".volta/tools/image/packages/@piagent/platform")
        let voltaRoot = try piagent(image)
        XCTAssertEqual(try StudioManagedConfiguration.runtimeRoot(home: volta, system: []), voltaRoot.resolvingSymlinksInPath())
        // A custom npm prefix (the usual fix for EACCES).
        let custom = try self.home()
        try pi(custom.appendingPathComponent(".npm-global"))
        XCTAssertEqual(try StudioClientConfiguration.piExecutable(home: custom, system: []), custom.appendingPathComponent(".npm-global/bin/pi"))
    }

    func testTheQualifiedPiHostWinsWhenSeveralAreInstalled() throws {
        let home = try home()
        try pi(home.appendingPathComponent(".pi/npm-global"), version: "0.86.0")
        let nvm = home.appendingPathComponent(".nvm/versions/node/v24.11.1")
        try pi(nvm)
        XCTAssertEqual(try StudioClientConfiguration.piExecutable(home: home, system: []), nvm.appendingPathComponent("bin/pi"))
    }
}

extension StudioManagedTests {
    /// The member's own `piagent` command recorded where it runs; the import
    /// pins exactly that entrypoint, Node and Pi host, even with nvm only.
    func testManagedImportPinsThePiagentTheMemberRuns() throws {
        let (base, _, _, _, helper, dir) = try managedRuntime()
        let prefix = base.appendingPathComponent(".nvm/versions/node/v24.11.1")
        let root = prefix.appendingPathComponent("lib/node_modules/@piagent/platform"), sdk = prefix.appendingPathComponent("lib/node_modules/@earendil-works/pi-coding-agent")
        let entry = root.appendingPathComponent("scripts/piagent-studio.mjs"), node = prefix.appendingPathComponent("bin/node")
        for (file, content, mode) in [(root.appendingPathComponent("package.json"), #"{"name":"@piagent/platform","version":"1.9.0"}"#, 0o600),
                                      (entry, "#!/usr/bin/env node\n", 0o700), (node, "#!/bin/sh\necho v24.11.1\n", 0o700),
                                      (sdk.appendingPathComponent("package.json"), #"{"name":"@earendil-works/pi-coding-agent","version":"0.87.1"}"#, 0o600)] {
            try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
            try Data(content.utf8).write(to: file); try FileManager.default.setAttributes([.posixPermissions: mode], ofItemAtPath: file.path)
        }
        let (profile, manifest) = try configuration()
        let pinned = { () throws -> [String: Any] in
            let plan = try StudioManagedConfiguration.prepare(directory: dir, connection: profile, manifest: manifest, helper: helper)
            return try XCTUnwrap(JSONSerialization.jsonObject(with: plan.edits[0].after) as? [String: Any])
        }
        let record = dir.appendingPathComponent("piagent-runtime.json")
        try JSONSerialization.data(withJSONObject: ["schema_version": 1, "entrypoint": entry.path, "node": node.path, "pi_sdk_root": sdk.path]).write(to: record)
        var binding = try pinned()
        XCTAssertEqual(binding["entrypoint"] as? String, entry.path)
        XCTAssertEqual(binding["node"] as? String, node.path)
        XCTAssertEqual(binding["sdk_root"] as? String, sdk.path)
        // Without a recorded Node, the Node beside the install (same npm prefix) is used.
        try JSONSerialization.data(withJSONObject: ["schema_version": 1, "entrypoint": entry.path, "pi_sdk_root": sdk.path]).write(to: record)
        binding = try pinned()
        XCTAssertEqual(binding["node"] as? String, node.path)
        // A record that does not point at an installed Piagent is ignored.
        try JSONSerialization.data(withJSONObject: ["schema_version": 1, "entrypoint": helper.path]).write(to: record)
        XCTAssertNil(StudioManagedConfiguration.registeredRuntime(directory: dir))
    }
}
