import XCTest
@testable import AgentWatchCore

/// `runtime = pi` is an added path. These tests keep the Piagent path's binding
/// and Terminal command byte for byte, and pin the Pi path's argv, environment
/// and directories. Everything lives under a disposable folder.
final class StudioManagedPiRuntimeTests: XCTestCase {
    let org = UUID(), owner = UUID(), team = UUID(), keyID = UUID(), instance = UUID(), epoch = UUID(), profileID = UUID()
    func configuration(runtime: String? = nil) throws -> (StudioProfile, StudioManifest) {
        let origin = try StudioOrigin("http://127.0.0.1:17921")
        let profile = try StudioProfile(origin: origin, id: origin.credentialSlotID(orgID: org, ownerID: owner, keyID: keyID, mode: .managed), connectionID: origin.profileID(orgID: org, ownerID: owner), keyID: keyID, credentialMode: .managed)
        let role = StudioHarnessRole(mode: "fixed", modelIDs: ["company-main"])
        let harness = StudioHarness(id: profileID, teamID: team, revision: 1, configuration: .init(main: role, research: role, review: nil))
        let user = StudioUser(id: owner, displayName: "Fixture", role: "member", active: true, version: 1, teamID: team)
        let manifest = StudioManifest(authority: StudioAuthority(instanceID: instance, epoch: epoch, generation: 1), harness: harness, runtime: runtime, schemaVersion: 2, revision: String(repeating: "a", count: 64), orgID: org, user: user, keyID: keyID, credentialMode: .managed, expiresAt: Date().addingTimeInterval(3600), refreshSeconds: 300, models: [], codexCatalog: .object([:]))
        return (profile, manifest)
    }
    func scratch() throws -> URL {
        let base = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".cache/watch-pi-runtime-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: base) }
        return base
    }
    func write(_ text: String, _ file: URL, executable: Bool = false) throws {
        try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(text.utf8).write(to: file)
        if executable { try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: file.path) }
    }
    func helper(_ base: URL) throws -> URL { let h = base.appendingPathComponent("agentwatch"); try write("#!/bin/sh\nexit 0\n", h, executable: true); return h }
    /// A bundle as piagent-bundle lays it out: Pi plus harness/sandbox/provider and manifest.json.
    func bundle(root: URL) throws { try bundle(at: StudioManagedPiRuntime.bundleDirectory(root: root)) }
    func bundle(at dir: URL, version: String = "0.1.0") throws {
        try write("#!/bin/sh\nout=\"$PI_CODING_AGENT_DIR/dump\"\nenv | sort > \"$out.env\"\nprintf '%s\\n' \"$@\" > \"$out.argv\"\npwd > \"$out.pwd\"\n", dir.appendingPathComponent("pi/bin/pi"), executable: true)
        for name in ["harness", "sandbox", "provider"] { try write("export default {}\n", dir.appendingPathComponent("\(name)/index.js")) }
        var parts: [String: Any] = [:]
        for name in StudioManagedPiRuntime.parts {
            parts[name] = ["version": "1.0.0", "path": name, "sha256": try StudioManagedPiRuntime.hashDirectory(dir.appendingPathComponent(name))]
        }
        try Data(JSONSerialization.data(withJSONObject: ["schema": 1, "bundleVersion": version, "piVersion": "1.3.0", "parts": parts])).write(to: dir.appendingPathComponent("manifest.json"))
    }
    func syncedRoot() throws -> (base: URL, root: URL, profile: StudioProfile) {
        let base = try scratch(), root = base.appendingPathComponent("ManagedPi")
        try bundle(root: root)
        let (profile, manifest) = try configuration(runtime: "pi")
        try StudioClientConfiguration.apply(StudioManagedPiRuntime.prepare(root: root, connection: profile, manifest: manifest, helper: helper(base)))
        return (base, root, profile)
    }

    func testRuntimeFieldDefaultsToPiagent() throws {
        XCTAssertEqual(StudioManagedRuntime.from(nil), .piagent)
        XCTAssertEqual(StudioManagedRuntime.from("piagent"), .piagent)
        XCTAssertEqual(StudioManagedRuntime.from("something-new"), .piagent)
        XCTAssertEqual(StudioManagedRuntime.from("pi"), .pi)
        let (_, plain) = try configuration()
        let encoded = String(decoding: try JSONEncoder().encode(plain), as: UTF8.self)
        XCTAssertFalse(encoded.contains("\"runtime\""), "an unchanged manifest encodes as before")
        XCTAssertNil(try JSONDecoder().decode(StudioManifest.self, from: Data(encoded.utf8)).runtime)
        let (_, pi) = try configuration(runtime: "pi")
        XCTAssertEqual(try JSONDecoder().decode(StudioManifest.self, from: JSONEncoder().encode(pi)).runtime, "pi")
    }

    func testDirectoryHashMatchesTheBundlesNodeImplementation() throws {
        let base = try scratch()
        for (path, text) in [("a.txt", "alpha"), ("sub/b.txt", "beta\n"), ("Zed/z.txt", "z"), ("_m", "m")] { try write(text, base.appendingPathComponent(path)) }
        XCTAssertEqual(try StudioManagedPiRuntime.hashDirectoryLegacy(base), "7855bf1036f80fb9c73e557d5b4ff2ca72313675b25d1d3c5dd4f7a80d13970e")
    }
    /// Format v2 (piagent-bundle#12): links, folders, execute and write bits count. Digest taken from that branch's `hashDir`.
    func testDirectoryHashV2MatchesTheBundlesNodeImplementation() throws {
        let base = try scratch(), fm = FileManager.default
        try write("alpha", base.appendingPathComponent("a.txt")); try write("beta\n", base.appendingPathComponent("sub/b.sh"))
        try fm.createDirectory(at: base.appendingPathComponent("empty"), withIntermediateDirectories: true)
        try fm.createSymbolicLink(atPath: base.appendingPathComponent("link").path, withDestinationPath: "a.txt")
        for (path, mode) in [("a.txt", 0o644), ("sub/b.sh", 0o755), ("sub", 0o755), ("empty", 0o755)] { try fm.setAttributes([.posixPermissions: mode], ofItemAtPath: base.appendingPathComponent(path).path) }
        XCTAssertEqual(try StudioManagedPiRuntime.hashDirectory(base), "c9512103ac2254c9071e81c10309dab61d7777e0b093de33d88059e30eadfde9")
        try fm.setAttributes([.posixPermissions: 0o664], ofItemAtPath: base.appendingPathComponent("a.txt").path)
        XCTAssertNotEqual(try StudioManagedPiRuntime.hashDirectory(base), "c9512103ac2254c9071e81c10309dab61d7777e0b093de33d88059e30eadfde9", "a group write bit changes the digest")
    }

    /// The Piagent path: binding and Terminal command are exactly what they were
    /// before `runtime` existed (snapshot taken on the commit before this change).
    func testPiagentPathIsUnchangedWhateverTheRuntimeField() throws {
        var snapshots: [String] = []
        for runtime in [nil, "piagent", "unknown"] as [String?] {
            let base = try scratch(), agent = base.appendingPathComponent("agent"), sdk = base.appendingPathComponent("sdk"), platform = base.appendingPathComponent("platform")
            try write("#!/usr/bin/env node\nconsole.log(1);\n", platform.appendingPathComponent("scripts/piagent-studio.mjs"), executable: true)
            try write("#!/bin/sh\nexit 0\n", sdk.appendingPathComponent("dist/cli/index.js"), executable: true)
            try write(#"{"version":"0.87.1"}"#, sdk.appendingPathComponent("package.json"))
            try FileManager.default.createDirectory(at: agent, withIntermediateDirectories: true)
            let (profile, manifest) = try configuration(runtime: runtime)
            let plan = try StudioManagedConfiguration.prepare(directory: agent, connection: profile, manifest: manifest, helper: helper(base), runtimeRoot: platform, piExecutable: sdk.appendingPathComponent("dist/cli/index.js"))
            XCTAssertEqual(plan.edits.map { $0.file.lastPathComponent }, ["agent-watch-managed.json"])
            XCTAssertEqual(plan.edits[0].file.deletingLastPathComponent().path, agent.path, "the binding stays in the Pi directory the sync was given")
            try StudioClientConfiguration.apply(plan)
            let launch = try StudioManagedConfiguration.terminal(directory: agent, project: base, profileID: profile.id, launchDirectory: base.appendingPathComponent("launches"))
            let script = try String(contentsOf: launch.url, encoding: .utf8)
            let binding = String(decoding: plan.edits[0].after, as: UTF8.self)
            let pinned = try JSONSerialization.jsonObject(with: plan.edits[0].after) as? [String: Any] ?? [:]
            func normal(_ text: String) -> String {
                var out = text.replacingOccurrences(of: base.path, with: "<BASE>").replacingOccurrences(of: profile.id, with: "<PROFILE>")
                out = out.replacingOccurrences(of: #"[0-9a-f-]{36}\.command"#, with: "<UUID>.command", options: .regularExpression)
                if let node = pinned["node"] as? String { out = out.replacingOccurrences(of: node, with: "<NODE>") }
                if let sha = pinned["node_sha256"] as? String { out = out.replacingOccurrences(of: sha, with: "<NODESHA>") }
                return out
            }
            snapshots.append(normal(binding) + "\n----\n" + normal(script))
        }
        XCTAssertEqual(Set(snapshots).count, 1, "a manifest without, or with another, runtime opens exactly the same")
        XCTAssertEqual(snapshots[0], Self.piagentGolden)
    }
    static let piagentGolden = #"""
{
  "broker" : "<BASE>/agentwatch",
  "broker_sha256" : "306c6ca7407560340797866e077e053627ad409277d1b9da58106fce4cf717cb",
  "configuration_revision" : "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa",
  "entrypoint" : "<BASE>/platform/scripts/piagent-studio.mjs",
  "entrypoint_sha256" : "0728dcd9e81d836c886b1a2f9d201e0ee6806bc84c46bfa58642911a13242315",
  "model" : "agent-watch-auto",
  "node" : "<NODE>",
  "node_sha256" : "<NODESHA>",
  "origin" : "http://127.0.0.1:17921",
  "profile_id" : "<PROFILE>",
  "schema_version" : 1,
  "sdk_root" : "<BASE>/sdk"
}

----
#!/bin/sh
umask 077
/bin/rm -f -- '<BASE>/launches/<UUID>.command'
exec /usr/bin/env -i PATH=/usr/bin:/bin TERM=xterm-256color LANG=en_US.UTF-8 '<NODE>' '<BASE>/platform/scripts/piagent-studio.mjs' '--config' '<BASE>/agent/agent-watch-managed.json' '--project' '<BASE>'

"""#

    // The bundle is the global npm package @piagent/pi-bundle, found under any npm prefix.
    func npmBundle(_ prefix: URL, version: String = "0.1.1") throws -> URL {
        let dir = prefix.appendingPathComponent(StudioManagedPiRuntime.npmSuffix, isDirectory: true)
        try bundle(at: dir, version: version); return dir
    }
    func search(_ home: URL, system: [URL] = []) -> StudioManagedPiRuntime.BundleSearch { .init(home: home, system: system) }
    func realURL(_ url: URL) -> URL { URL(fileURLWithPath: StudioManagedPiRuntime.realPath(url)!) }

    func testBundleIsFoundUnderEveryNpmPrefixKind() throws {
        let prefixes: [(String, (URL) -> URL)] = [
            ("nvm", { $0.appendingPathComponent(".nvm/versions/node/v22.19.0") }),
            ("npm-global", { $0.appendingPathComponent(".npm-global") }),
            ("volta", { $0.appendingPathComponent(".volta/tools/image/packages/@piagent/pi-bundle") }),
            ("fnm", { $0.appendingPathComponent(".local/share/fnm/node-versions/v24.1.0/installation") }),
            ("local", { $0.appendingPathComponent(".local") }),
        ]
        for (name, prefix) in prefixes {
            let home = try scratch()
            let dir = try npmBundle(prefix(home))
            let found = StudioManagedPiRuntime.locateBundle(root: home.appendingPathComponent("ManagedPi"), search: search(home))
            XCTAssertEqual(found?.path, realURL(dir).path, name)
        }
        let system = try scratch(), home = try scratch()
        let dir = try npmBundle(system)
        XCTAssertEqual(StudioManagedPiRuntime.locateBundle(root: home, search: search(home, system: [system]))?.path, realURL(dir).path, "system prefix")
    }

    func testNpmBundleIsPinnedAndOpensFromItsPrefixAndLegacyStaysCompatible() throws {
        let base = try scratch(), home = base.appendingPathComponent("home"), root = base.appendingPathComponent("ManagedPi")
        let dir = try npmBundle(home.appendingPathComponent(".nvm/versions/node/v22.19.0"))
        let (profile, manifest) = try configuration(runtime: "pi")
        try StudioClientConfiguration.apply(StudioManagedPiRuntime.prepare(root: root, connection: profile, manifest: manifest, helper: helper(base), search: search(home)))
        let binding = try StudioClientConfiguration.object(StudioClientConfiguration.read(StudioManagedPiRuntime.bindingURL(root: root)))
        XCTAssertEqual(binding["bundle_root"] as? String, realURL(dir).path)
        XCTAssertEqual(binding["bundle_version"] as? String, "0.1.1")
        let plan = try StudioManagedPiRuntime.launch(root: root, profileID: profile.id)
        XCTAssertEqual(plan.executable, realURL(dir).appendingPathComponent("pi/bin/pi").path)
        XCTAssertEqual(plan.environment["PI_CODING_AGENT_DIR"], root.path + "/agent", "own directories, not the package's")
        // Nothing of the trial location is needed any more, and a bundle at <root>/bundle alone still works (the first trial build).
        let legacyBase = try scratch(), legacyRoot = legacyBase.appendingPathComponent("ManagedPi")
        try bundle(root: legacyRoot)
        XCTAssertEqual(StudioManagedPiRuntime.locateBundle(root: legacyRoot, search: search(try scratch()))?.path, StudioManagedPiRuntime.bundleDirectory(root: legacyRoot).path)
        try StudioClientConfiguration.apply(StudioManagedPiRuntime.prepare(root: legacyRoot, connection: profile, manifest: manifest, helper: helper(legacyBase), search: search(try scratch())))
        XCTAssertNoThrow(try StudioManagedPiRuntime.launch(root: legacyRoot, profileID: profile.id))
    }

    func testAVerifyingNpmInstallBeatsACorruptOneAndTheOlderLocation() throws {
        let base = try scratch(), home = base.appendingPathComponent("home"), root = base.appendingPathComponent("ManagedPi")
        let bad = try npmBundle(home.appendingPathComponent(".local"))
        try write("tampered", bad.appendingPathComponent("harness/index.js"))
        let good = try npmBundle(home.appendingPathComponent(".nvm/versions/node/v22.19.0"))
        try bundle(root: root)
        XCTAssertEqual(StudioManagedPiRuntime.locateBundle(root: root, search: search(home))?.path, realURL(good).path)
        // Only a corrupt one: it is still the one reported, so the error names its problem and the repair command.
        try FileManager.default.removeItem(at: good)
        try FileManager.default.removeItem(at: StudioManagedPiRuntime.bundleDirectory(root: root))
        let (profile, manifest) = try configuration(runtime: "pi")
        XCTAssertThrowsError(try StudioManagedPiRuntime.prepare(root: root, connection: profile, manifest: manifest, helper: helper(base), search: search(home))) {
            guard case StudioPiRuntimeError.bundleMismatch(let issues) = $0 else { return XCTFail("\($0)") }
            XCTAssertEqual(issues, ["hash-mismatch:harness"])
        }
    }

    func testMissingBundleNamesTheInstallCommandAndRepairTerminalRunsIt() throws {
        let base = try scratch(), (profile, manifest) = try configuration(runtime: "pi")
        XCTAssertThrowsError(try StudioManagedPiRuntime.prepare(root: base.appendingPathComponent("ManagedPi"), connection: profile, manifest: manifest, helper: helper(base), search: search(base))) {
            XCTAssertEqual($0 as? StudioPiRuntimeError, .bundleMissing)
            XCTAssertTrue($0.localizedDescription.contains("npm install --global --ignore-scripts @piagent/pi-bundle"), $0.localizedDescription)
            XCTAssertTrue($0.localizedDescription.contains("Sửa cài đặt"))
        }
        XCTAssertTrue(StudioPiRuntimeError.bundleMismatch(["hash-mismatch:pi"]).localizedDescription.contains("--force @piagent/pi-bundle"))
        XCTAssertFalse(StudioPiRuntimeError.bindingMissing.isRepairable)
        let launchDirectory = base.appendingPathComponent("launch")
        let command = try StudioManagedPiRuntime.repairTerminal(repair: false, launchDirectory: launchDirectory)
        let script = try String(contentsOf: command.url, encoding: .utf8)
        XCTAssertTrue(script.contains("exec /bin/zsh -lic"), script)
        XCTAssertTrue(script.contains("npm install --global --ignore-scripts @piagent/pi-bundle"), script)
        XCTAssertFalse(script.contains("--force"))
        XCTAssertEqual(try FileManager.default.attributesOfItem(atPath: command.url.path)[.posixPermissions] as? Int, 0o700)
        let again = try String(contentsOf: StudioManagedPiRuntime.repairTerminal(repair: true, launchDirectory: launchDirectory).url, encoding: .utf8)
        XCTAssertTrue(again.contains("--force @piagent/pi-bundle"), again)
    }

    func testBindingCannotNameAnArbitraryBundleLocation() throws {
        let (base, root, profile) = try syncedRoot()
        let file = StudioManagedPiRuntime.bindingURL(root: root)
        var object = try StudioClientConfiguration.object(StudioClientConfiguration.read(file))
        let elsewhere = base.appendingPathComponent("elsewhere/bundle"); try bundle(at: elsewhere)
        object["bundle_root"] = elsewhere.path
        try Data(JSONSerialization.data(withJSONObject: object)).write(to: file)
        XCTAssertThrowsError(try StudioManagedPiRuntime.launch(root: root, profileID: profile.id)) { XCTAssertEqual($0 as? StudioPiRuntimeError, .bindingChanged) }
    }

    func testPiPathUsesTheBundlesOwnPiAndSeparateDirectories() throws {
        let (base, root, profile) = try syncedRoot()
        let plan = try StudioManagedPiRuntime.launch(root: root, profileID: profile.id)
        let bundle = StudioManagedPiRuntime.bundleDirectory(root: root)
        XCTAssertEqual(plan.executable, bundle.appendingPathComponent("pi/bin/pi").path)
        XCTAssertEqual(plan.arguments, ["--no-extensions", "--no-approve", "--no-skills", "--no-prompt-templates", "--offline", "-e", bundle.path + "/harness", "-e", bundle.path + "/sandbox", "-e", bundle.path + "/provider", "-e", "builtin:mcp"])
        XCTAssertEqual(Set(plan.environment.keys), ["PATH", "TERM", "LANG", "PI_CODING_AGENT_DIR", "PI_CODING_AGENT_SESSION_DIR", "AGENT_WATCH_MANAGED_BINDING", "PI_OFFLINE", "PI_TELEMETRY", "PI_SKIP_VERSION_CHECK"])
        XCTAssertEqual([plan.environment["PI_OFFLINE"], plan.environment["PI_TELEMETRY"], plan.environment["PI_SKIP_VERSION_CHECK"]], ["1", "0", "1"])
        XCTAssertEqual(plan.environment["PI_CODING_AGENT_DIR"], root.path + "/agent")
        XCTAssertEqual(plan.environment["PI_CODING_AGENT_SESSION_DIR"], root.path + "/ManagedSessions")
        XCTAssertEqual(plan.environment["PATH"], "/usr/bin:/bin", "no pi from PATH")
        for value in [plan.executable] + plan.arguments + Array(plan.environment.values) {
            XCTAssertFalse(value.contains("/.pi/") || value.contains("/.piagent"), value)
            XCTAssertFalse(value.hasPrefix("/usr/local") || value.hasPrefix("/opt/homebrew"), value)
        }
        XCTAssertTrue(FileManager.default.fileExists(atPath: root.path + "/ManagedSessions"))
        _ = base
    }

    func testPiPathDoesNotTouchThePiagentBindingOrItsDirectory() throws {
        let base = try scratch(), root = base.appendingPathComponent("ManagedPi"), agent = base.appendingPathComponent("agent")
        try FileManager.default.createDirectory(at: agent, withIntermediateDirectories: true)
        try write(#"{"schema_version":1,"old":true}"#, agent.appendingPathComponent("agent-watch-managed.json"))
        try write(#"{"providers":{}}"#, agent.appendingPathComponent("models.json"))
        let before = try snapshot(agent)
        try bundle(root: root)
        let (profile, manifest) = try configuration(runtime: "pi")
        try StudioClientConfiguration.apply(StudioManagedPiRuntime.prepare(root: root, connection: profile, manifest: manifest, helper: helper(base)))
        _ = try StudioManagedPiRuntime.launch(root: root, profileID: profile.id)
        XCTAssertEqual(try snapshot(agent), before)
        XCTAssertTrue(FileManager.default.fileExists(atPath: StudioManagedPiRuntime.bindingURL(root: root).path))
        XCTAssertNotEqual(StudioManagedPiRuntime.bindingURL(root: root).lastPathComponent, "agent-watch-managed.json")
    }
    func snapshot(_ dir: URL) throws -> [String: Data] {
        var out: [String: Data] = [:]
        for case let url as URL in FileManager.default.enumerator(at: dir, includingPropertiesForKeys: nil)! where !url.hasDirectoryPath { out[url.path] = try Data(contentsOf: url) }
        return out
    }

    func testHashMismatchRefusesToOpenAndSuggestsRepair() throws {
        let (base, root, profile) = try syncedRoot()
        let launches = base.appendingPathComponent("launches")
        try write("export default { tampered: true }\n", StudioManagedPiRuntime.bundleDirectory(root: root).appendingPathComponent("sandbox/index.js"))
        XCTAssertThrowsError(try StudioManagedPiRuntime.terminal(root: root, project: base, profileID: profile.id, launchDirectory: launches)) {
            XCTAssertEqual($0 as? StudioPiRuntimeError, .bundleMismatch(["hash-mismatch:sandbox"]))
            XCTAssertTrue($0.localizedDescription.contains("Sửa cài đặt"))
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: launches.path), "nothing was written to open")
        let (_, manifest) = try configuration(runtime: "pi")
        XCTAssertThrowsError(try StudioManagedPiRuntime.prepare(root: root, connection: profile, manifest: manifest, helper: helper(base))) { _ in }
    }

    func testBrokerOrPiChangeAfterSyncRefuses() throws {
        let (base, root, profile) = try syncedRoot()
        try write("#!/bin/sh\necho changed\n", base.appendingPathComponent("agentwatch"), executable: true)
        XCTAssertThrowsError(try StudioManagedPiRuntime.launch(root: root, profileID: profile.id)) { XCTAssertEqual($0 as? StudioPiRuntimeError, .bindingChanged) }
        XCTAssertThrowsError(try StudioManagedPiRuntime.launch(root: root, profileID: String(repeating: "f", count: 64)))
    }

    /// Runs the real Terminal command with a poisoned parent environment: the
    /// Pi process sees only the closed environment, and no key anywhere.
    func testKeyNeverReachesThePiProcess() throws {
        let (base, root, profile) = try syncedRoot()
        let command = try StudioManagedPiRuntime.terminal(root: root, project: base, profileID: profile.id, launchDirectory: base.appendingPathComponent("launches"))
        let script = try String(contentsOf: command.url, encoding: .utf8)
        for secret in ["as_live_", "as_device_", "as_run_", "SECRET"] { XCTAssertFalse(script.contains(secret)) }
        let process = Process()
        process.executableURL = command.url
        process.environment = ["PATH": "/usr/bin:/bin", "AGENT_WATCH_KEY": "as_live_SECRETSECRET", "OPENAI_API_KEY": "sk-SECRET", "HOME": base.path]
        try process.run(); process.waitUntilExit()
        XCTAssertEqual(process.terminationStatus, 0)
        let dump = root.appendingPathComponent("agent/dump")
        let env = try String(contentsOf: URL(fileURLWithPath: dump.path + ".env"), encoding: .utf8), argv = try String(contentsOf: URL(fileURLWithPath: dump.path + ".argv"), encoding: .utf8)
        XCTAssertFalse(env.contains("SECRET")); XCTAssertFalse(argv.contains("SECRET"))
        XCTAssertFalse(env.contains("AGENT_WATCH_KEY")); XCTAssertFalse(env.contains("OPENAI_API_KEY")); XCTAssertFalse(env.contains("HOME="))
        XCTAssertTrue(env.contains("PI_CODING_AGENT_SESSION_DIR=" + root.path + "/ManagedSessions")); XCTAssertTrue(env.contains("PI_OFFLINE=1"))
        XCTAssertEqual(argv.split(separator: "\n").first, "--no-extensions")
        XCTAssertEqual(try String(contentsOf: URL(fileURLWithPath: dump.path + ".pwd"), encoding: .utf8).trimmingCharacters(in: .whitespacesAndNewlines), base.path)
    }

    func testManifestDigestIsPinnedLikeDoctorExpect() throws {
        let (base, root, profile) = try syncedRoot()
        let manifest = StudioManagedPiRuntime.bundleDirectory(root: root).appendingPathComponent("manifest.json")
        let text = try String(contentsOf: manifest, encoding: .utf8)
        try write(text + "\n", manifest)   // same parts, different manifest bytes
        XCTAssertThrowsError(try StudioManagedPiRuntime.launch(root: root, profileID: profile.id)) {
            XCTAssertEqual($0 as? StudioPiRuntimeError, .bundleMismatch(["manifest-digest-mismatch"]))
        }
        _ = base
    }

    /// F3: the broker is pinned by realpath(3), whatever symlinks lead to it (`/var` vs `/private/var`).
    func testBrokerBehindASymlinkIsPinnedByRealpath() throws {
        let base = try scratch(), root = base.appendingPathComponent("ManagedPi"), real = base.appendingPathComponent("real"), link = base.appendingPathComponent("link")
        try bundle(root: root)
        try write("#!/bin/sh\nexit 0\n", real.appendingPathComponent("agentwatch"), executable: true)
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: real)
        let (profile, manifest) = try configuration(runtime: "pi")
        let plan = try StudioManagedPiRuntime.prepare(root: root, connection: profile, manifest: manifest, helper: link.appendingPathComponent("agentwatch"))
        try StudioClientConfiguration.apply(plan)
        let object = try JSONSerialization.jsonObject(with: Data(contentsOf: StudioManagedPiRuntime.bindingURL(root: root))) as? [String: Any]
        var buffer = [CChar](repeating: 0, count: Int(PATH_MAX)); XCTAssertNotNil(realpath(real.appendingPathComponent("agentwatch").path, &buffer))
        XCTAssertEqual(object?["broker"] as? String, String(cString: buffer))
        XCTAssertNoThrow(try StudioManagedPiRuntime.launch(root: root, profileID: profile.id))
    }

    func testSwitchingBackToPiagentRetiresOnlyThePiBinding() throws {
        let (base, root, profile) = try syncedRoot()
        let other = base.appendingPathComponent("agent"); try write("{}", other.appendingPathComponent("agent-watch-managed.json"))
        XCTAssertEqual(StudioManagedPiRuntime.pinnedBundleVersion(root: root, profileID: profile.id), "0.1.0")
        StudioManagedPiRuntime.retire(root: root)
        XCTAssertNil(StudioManagedPiRuntime.pinnedBundleVersion(root: root, profileID: profile.id))
        XCTAssertEqual(try String(contentsOf: other.appendingPathComponent("agent-watch-managed.json"), encoding: .utf8), "{}")
        XCTAssertNil(StudioManagedPiRuntime.pinnedBundleVersion(root: root, profileID: String(repeating: "f", count: 64)))
    }

    // MARK: F2 · bundle version on `start`, and 426 `bundle_too_old`

    func token(_ kind: String, _ id: UUID) -> String { "as_\(kind)_\(id.uuidString.lowercased())_" + String(repeating: "x", count: 43) }
    func grant(_ run: UUID, _ role: UUID) -> [String: Any] {
        ["run_id": run.uuidString, "role_id": role.uuidString, "role": "main", "model_id": "company-main", "provider": "codex", "provider_model_id": "gpt-6-sol", "effort": "medium", "fence": 1,
         "token": token("run", role), "expires_at": "2026-01-01T00:00:00Z", "profile_id": profileID.uuidString, "studio_instance_id": instance.uuidString, "dataset_epoch": epoch.uuidString, "auth_generation": 1]
    }
    /// A Studio that holds a floor of 0.2.0: a body without a bundle version at or above it is refused with 426.
    actor FloorStudio: StudioHTTPTransport {
        var bodies: [Data] = []
        let granted: Data
        init(_ granted: Data) { self.granted = granted }
        func send(_ request: URLRequest, origin: StudioOrigin) async throws -> StudioHTTPResponse {
            let raw = request.httpBody ?? Data(), body = (try? JSONSerialization.jsonObject(with: raw)) as? [String: Any] ?? [:]
            bodies.append(raw)
            let version = (body["bundle_version"] as? String ?? "").split(separator: ".").compactMap { Int($0.prefix { $0.isNumber }) }
            if !(version.count == 3 && version.lexicographicallyPrecedes([0, 2, 0]) == false) {
                return StudioHTTPResponse(status: 426, body: Data(#"{"error":{"code":"bundle_too_old","message":"x"}}"#.utf8))
            }
            return StudioHTTPResponse(status: 201, body: granted)
        }
        func sent() -> [Data] { bodies }
    }
    @MainActor func broker(_ transport: FloorStudio, bundleVersion: String?) throws -> StudioManagedBroker {
        let (profile, manifest) = try configuration(runtime: "pi")
        let id = UUID()
        let real = StudioManagedDevice(deviceID: id, token: token("device", id), expiresAt: Date(), instanceID: instance, epoch: epoch, generation: 1)
        return try StudioManagedBroker(profile: profile, manifest: manifest, device: real, client: StudioManagedClient(transport: transport), bundleVersion: bundleVersion)
    }
    @MainActor func testStartSendsTheBundleVersionAndAFreshBundleGetsARun() async throws {
        let studio = FloorStudio(try JSONSerialization.data(withJSONObject: grant(UUID(), UUID())))
        let granted = try await broker(studio, bundleVersion: "0.2.1").start(operation: UUID(), effort: "medium", taskClass: "simple")
        XCTAssertEqual(granted.role, "main")
        let sent = await studio.sent().compactMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] }
        XCTAssertEqual(sent.first?["bundle_version"] as? String, "0.2.1")
    }
    @MainActor func testOldOrMissingBundleIsRefusedWithAClearMessage() async throws {
        for version in ["0.1.9", nil] as [String?] {
            let studio = FloorStudio(try JSONSerialization.data(withJSONObject: grant(UUID(), UUID())))
            do { _ = try await broker(studio, bundleVersion: version).start(operation: UUID(), effort: "medium", taskClass: "simple"); XCTFail("accepted") }
            catch {
                XCTAssertEqual(error as? StudioManagedRefusal, StudioManagedRefusal(error: .bundleTooOld, code: "bundle_too_old"))
                let text = StudioError.bundleTooOld.errorDescription ?? ""
                XCTAssertTrue(text.contains("Sửa cài đặt") && text.contains("quá cũ"))
            }
        }
    }
    /// The Piagent path sends exactly the body it always did.
    @MainActor func testPiagentStartBodyIsUnchanged() async throws {
        let studio = FloorStudio(try JSONSerialization.data(withJSONObject: grant(UUID(), UUID())))
        _ = try? await broker(studio, bundleVersion: nil).start(operation: UUID(), effort: "medium", taskClass: "simple")
        let sent = await studio.sent().compactMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] }
        XCTAssertEqual(Set(sent[0].keys), ["operation_id", "effort", "task_class"])
    }
}
