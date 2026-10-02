import Foundation
import CryptoKit
import Darwin

public enum StudioManagedConfiguration {
    public static func authorize(directory: URL, profileID: String) async throws {
        let object = try StudioClientConfiguration.object(StudioClientConfiguration.read(directory.appendingPathComponent("agent-watch-managed.json")))
        guard object["profile_id"] as? String == profileID,
              let broker = object["broker"] as? String, let expected = object["broker_sha256"] as? String,
              broker.hasPrefix("/"), URL(fileURLWithPath: broker).resolvingSymlinksInPath().path == broker,
              SHA256.hash(data: try Data(contentsOf: URL(fileURLWithPath: broker))).map({ String(format: "%02x", $0) }).joined() == expected else { throw StudioCLIError.runtimeChanged }
        let allowed = try await Task.detached {
            let process = Process()
            process.executableURL = URL(fileURLWithPath: broker)
            process.arguments = ["managed-authorize", "--profile", profileID]
            process.environment = ["PATH": "/usr/bin:/bin", "LANG": "en_US.UTF-8"]
            process.standardInput = FileHandle.nullDevice; process.standardOutput = FileHandle.nullDevice; process.standardError = FileHandle.nullDevice
            try process.run()
            let deadline = Date().addingTimeInterval(180)
            while process.isRunning && Date() < deadline { usleep(50_000) }
            if process.isRunning { kill(process.processIdentifier, SIGKILL) }
            process.waitUntilExit()
            return process.terminationStatus == 0
        }.value
        guard allowed else { throw StudioError.keychainApprovalRequired }
    }
    /// A global `@piagent/platform` install, wherever the member's npm put it.
    public static func runtimeRoot(home: URL = FileManager.default.homeDirectoryForCurrentUser,
                                   system: [URL] = ["/usr/local", "/opt/homebrew"].map { URL(fileURLWithPath: $0) }) throws -> URL {
        let prefixes = [home.appendingPathComponent(".local")] + system + [home.appendingPathComponent(".pi/npm-global")]
            + StudioInstallLocations.userPrefixes(home: home, package: "@piagent/platform") + StudioInstallLocations.versionManagedPrefixes(home: home)
        for prefix in prefixes {
            let root = prefix.appendingPathComponent("lib/node_modules/@piagent/platform").resolvingSymlinksInPath()
            if FileManager.default.isExecutableFile(atPath: root.appendingPathComponent("scripts/piagent-studio.mjs").path) { return root }
        }
        throw StudioCLIError.binaryMissing
    }
    /// The Piagent this member runs, as its `piagent` command recorded it:
    /// installed entrypoint, the Node running it and the Pi host on PATH.
    struct RegisteredRuntime { let root: URL; let node: URL?; let sdk: URL? }
    static func registeredRuntime(directory: URL) -> RegisteredRuntime? {
        guard let object = try? StudioClientConfiguration.object(StudioClientConfiguration.read(directory.appendingPathComponent("piagent-runtime.json"))),
              object["schema_version"] as? Int == 1, let path = object["entrypoint"] as? String, path.hasPrefix("/") else { return nil }
        let entry = URL(fileURLWithPath: path).resolvingSymlinksInPath(), root = entry.deletingLastPathComponent().deletingLastPathComponent()
        guard entry.lastPathComponent == "piagent-studio.mjs", entry.deletingLastPathComponent().lastPathComponent == "scripts",
              FileManager.default.isExecutableFile(atPath: entry.path), StudioInstallLocations.packageField(root, "name") == "@piagent/platform" else { return nil }
        let absolute = { (key: String) in (object[key] as? String).flatMap { $0.hasPrefix("/") ? URL(fileURLWithPath: $0) : nil } }
        let sdk = absolute("pi_sdk_root").flatMap { StudioInstallLocations.packageField($0, "name") == "@earendil-works/pi-coding-agent" ? $0 : nil }
        return RegisteredRuntime(root: root, node: absolute("node"), sdk: sdk)
    }
    public static func receiptURL(directory: URL) -> URL {
        StudioClientConfiguration.receiptURL(tool: .pi, directory: directory.appendingPathComponent(".agent-watch-managed"))
    }
    public static func prepare(directory: URL, connection: StudioProfile, manifest: StudioManifest, helper: URL,
                               runtimeRoot explicitRoot: URL? = nil, piExecutable explicitPi: URL? = nil) throws -> StudioConfigurationPlan {
        try manifest.validate(profile: connection)
        guard connection.credentialMode == .managed, manifest.harness != nil else { throw StudioError.permissionDenied }
        let receipt = receiptURL(directory: directory)
        if let previous = try StudioClientConfiguration.read(receipt) {
            let old = try JSONDecoder().decode(StudioConfigurationPlan.self, from: previous)
            guard old.profileID == connection.id else { throw StudioConfigurationError.destinationInUse }
        }
        let registered = explicitRoot == nil ? registeredRuntime(directory: directory) : nil
        let root = try explicitRoot ?? registered?.root ?? runtimeRoot()
        // Node that runs this install: as registered, then the one npm used
        // (<prefix>/lib/node_modules/@piagent/platform -> <prefix>/bin/node).
        let prefix = root.deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let nodes = [registered?.node, prefix.appendingPathComponent("bin/node")].compactMap { $0 } + StudioRuntimeBinding.defaultNodeCandidates()
        let binding = try StudioRuntimeBinding.resolve(entrypoint: root.appendingPathComponent("scripts/piagent-studio.mjs"), nodeCandidates: nodes)
        guard let node = binding.interpreter else { throw StudioCLIError.runtimeMissing }
        let sdk: URL
        if explicitPi == nil, let host = registered?.sdk, StudioInstallLocations.packageField(host, "version") == "0.87.1" { sdk = host.resolvingSymlinksInPath() }
        else { sdk = try (explicitPi ?? StudioClientConfiguration.piExecutable()).resolvingSymlinksInPath().deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent() }
        let package = try StudioClientConfiguration.object(StudioClientConfiguration.read(sdk.appendingPathComponent("package.json")))
        guard package["version"] as? String == "0.87.1", helper.isFileURL,
              FileManager.default.isExecutableFile(atPath: helper.path) else { throw StudioCLIError.unsupportedVersion }
        let broker = helper.resolvingSymlinksInPath()
        let brokerHash = SHA256.hash(data: try Data(contentsOf: broker)).map { String(format: "%02x", $0) }.joined()
        let file = directory.appendingPathComponent("agent-watch-managed.json")
        let object: [String: Any] = ["schema_version": 1, "model": "agent-watch-auto", "profile_id": connection.id, "origin": connection.origin.value,
            "node": node.path, "entrypoint": binding.entrypoint.path, "node_sha256": binding.interpreterSHA256!, "entrypoint_sha256": binding.entrypointSHA256,
            "sdk_root": sdk.path, "broker": broker.path, "broker_sha256": brokerHash,
            "configuration_revision": manifest.revision]
        return StudioConfigurationPlan(edits: [.init(file: file, before: try StudioClientConfiguration.read(file), after: try StudioClientConfiguration.encoded(object))], tool: .pi, profileID: connection.id)
    }
    public static func terminal(directory: URL, project: URL, profileID: String, web: Bool = false, launchDirectory: URL = StudioTerminalCommand.directory) throws -> StudioTerminalCommand {
        let file = directory.appendingPathComponent("agent-watch-managed.json")
        let object = try StudioClientConfiguration.object(StudioClientConfiguration.read(file))
        guard object["profile_id"] as? String == profileID, let node = object["node"] as? String, let entry = object["entrypoint"] as? String,
              let nodeHash = object["node_sha256"] as? String, let entryHash = object["entrypoint_sha256"] as? String,
              project.isFileURL, (try? project.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true else { throw StudioCLIError.invalidArguments }
        let binding = try StudioRuntimeBinding.resolve(entrypoint: URL(fileURLWithPath: entry), node: URL(fileURLWithPath: node))
        guard binding.interpreterSHA256 == nodeHash, binding.entrypointSHA256 == entryHash else { throw StudioCLIError.runtimeChanged }
        try StudioCLIProfiles.privateDirectory(launchDirectory)
        let target = launchDirectory.appendingPathComponent(UUID().uuidString.lowercased() + ".command")
        let quote = StudioClientConfiguration.shellQuote
        let args = [node, entry, "--config", file.path, "--project", project.resolvingSymlinksInPath().path] + (web ? ["--web"] : [])
        let script = "#!/bin/sh\numask 077\n/bin/rm -f -- \(quote(target.path))\nexec /usr/bin/env -i PATH=/usr/bin:/bin TERM=xterm-256color LANG=en_US.UTF-8 \(args.map(quote).joined(separator: " "))\n"
        try Data(script.utf8).write(to: target, options: [.withoutOverwriting])
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: target.path)
        return StudioTerminalCommand(url: target)
    }
}
