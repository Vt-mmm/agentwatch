import Foundation
import CryptoKit

/// Which program a company conversation opens in. Studio states it in the
/// manifest (`runtime`); absent, or any value but "pi", is the Piagent that has
/// always run here, whose launcher and binding this file never touches.
public enum StudioManagedRuntime: String, Sendable {
    case piagent, pi
    public static func from(_ raw: String?) -> Self { raw == "pi" ? .pi : .piagent }
}

public enum StudioPiRuntimeError: Error, LocalizedError, Sendable, Equatable {
    case bundleMissing, bundleMismatch([String]), bindingMissing, bindingChanged
    public var errorDescription: String? {
        switch self {
        case .bundleMissing: "Chưa có bộ Pi của công ty. Dùng “Sửa cài đặt”, hoặc chạy trong Terminal: " + StudioManagedPiRuntime.installCommand(repair: false)
        case .bundleMismatch(let problems): "Bộ Pi không khớp bản đã pin (" + problems.joined(separator: ", ") + "). Chưa mở. Dùng “Sửa cài đặt”, hoặc chạy trong Terminal: " + StudioManagedPiRuntime.installCommand(repair: true) + ". Nếu bạn vừa cập nhật bộ, bấm Đồng bộ để ghim lại."
        case .bindingMissing: "Chưa đồng bộ cấu hình Pi của công ty. Mở lại sau khi đồng bộ."
        case .bindingChanged: "Broker hoặc Pi đã đổi so với lúc đồng bộ. Chưa mở. Dùng “Sửa cài đặt”, hoặc chạy trong Terminal: " + StudioManagedPiRuntime.installCommand(repair: true)
        }
    }
    /// The errors "Sửa cài đặt" can mend by running the install command.
    public var isRepairable: Bool { if case .bindingMissing = self { return false }; return true }
}

/// `runtime = pi`: the Pi of the company bundle (its own copy, pinned by hash)
/// with the three bundle packages. Everything it owns lives under one root
/// (`ManagedPi/`): the binding, `agent/` (PI_CODING_AGENT_DIR) and
/// `ManagedSessions/`. Nothing here reads or writes ~/.pi or ~/.piagent.
/// Spec: manifest.json of the bundle (piagent-bundle `src/manifest.mjs`).
public enum StudioManagedPiRuntime {
    public static let piVersion = "1.3.0"
    public static let parts = ["pi", "harness", "sandbox", "provider"]
    public static let bindingName = "agent-watch-managed-pi.json"
    public static var defaultRoot: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("AgentWatch/ManagedPi", isDirectory: true)
    }
    public static func bindingURL(root: URL) -> URL { root.appendingPathComponent(bindingName) }
    /// The first place the bundle was put (trial builds): `<root>/bundle`. Still accepted; the npm package is preferred.
    public static func bundleDirectory(root: URL) -> URL { root.appendingPathComponent("bundle", isDirectory: true) }

    /// The bundle is the global npm package `@piagent/pi-bundle`, installed by the member like `@piagent/platform`.
    /// Agent Watch does not install it: it looks under every npm prefix and pins the path and hashes it found.
    public static let npmPackage = "@piagent/pi-bundle"
    public static let npmSuffix = "lib/node_modules/@piagent/pi-bundle/bundle"
    public static func installCommand(repair: Bool) -> String { "npm install --global --ignore-scripts" + (repair ? " --force " : " ") + npmPackage }

    /// Where to look for the npm package. `nil` (the default of `prepare`) looks only at `<root>/bundle`.
    public struct BundleSearch: Sendable {
        public var home: URL, system: [URL]
        public init(home: URL, system: [URL]) { self.home = home; self.system = system }
        public static var standard: Self { .init(home: FileManager.default.homeDirectoryForCurrentUser, system: ["/usr/local", "/opt/homebrew"].map { URL(fileURLWithPath: $0) }) }
        var prefixes: [URL] {
            [home.appendingPathComponent(".local")] + system + StudioInstallLocations.userPrefixes(home: home, package: StudioManagedPiRuntime.npmPackage)
                + StudioInstallLocations.versionManagedPrefixes(home: home)
        }
    }
    /// The bundle to pin: the first npm install that verifies, else the first one found (so its problems are reported),
    /// else the older `<root>/bundle`. Paths of npm installs are resolved with realpath(3).
    public static func locateBundle(root: URL, search: BundleSearch?) -> URL? {
        var found: [URL] = (search?.prefixes ?? []).compactMap { prefix in
            let dir = prefix.appendingPathComponent(npmSuffix, isDirectory: true)
            return FileManager.default.fileExists(atPath: dir.appendingPathComponent("manifest.json").path) ? realPath(dir).map { URL(fileURLWithPath: $0) } : nil
        }
        let legacy = bundleDirectory(root: root)
        if FileManager.default.fileExists(atPath: legacy.appendingPathComponent("manifest.json").path) { found.append(legacy) }
        return found.first(where: { verified($0) }) ?? found.first
    }
    static func verified(_ bundle: URL) -> Bool {
        guard let data = try? Data(contentsOf: bundle.appendingPathComponent("manifest.json")), let object = try? StudioClientConfiguration.object(data),
              object["schema"] as? Int == 1 else { return false }
        return problems(bundle: bundle, parts: pinnedParts(object), piVersion: object["piVersion"] as? String ?? "").isEmpty
    }
    /// What the binding may name as the bundle: `<root>/bundle`, or a real path of the npm package.
    static func acceptedLocation(_ bundle: URL, root: URL) -> Bool {
        bundle == bundleDirectory(root: root) || (bundle.path.hasPrefix("/") && bundle.path.hasSuffix("/" + npmSuffix) && realPath(bundle) == bundle.path)
    }
    public static func agentDirectory(root: URL) -> URL { root.appendingPathComponent("agent", isDirectory: true) }
    public static func sessionDirectory(root: URL) -> URL { root.appendingPathComponent("ManagedSessions", isDirectory: true) }

    /// Same digest as the bundle's `hashDir` (format "v2", piagent-bundle `src/manifest.mjs`): every
    /// entry counts, with its type, execute bit and group/other write bit.
    public static func hashDirectory(_ dir: URL) throws -> String {
        var hash = SHA256()
        let put = { (text: String) in hash.update(data: Data(text.utf8)) }
        put("piagent-bundle-hash-v2\0")
        func walk(_ rel: String) throws {
            let abs = rel.isEmpty ? dir : dir.appendingPathComponent(rel)
            for name in try FileManager.default.contentsOfDirectory(atPath: abs.path).sorted(by: { $0.utf16.lexicographicallyPrecedes($1.utf16) }) {
                let next = rel.isEmpty ? name : rel + "/" + name, full = dir.appendingPathComponent(next)
                var info = stat(); guard lstat(full.path, &info) == 0 else { throw StudioConfigurationError.unsafe }
                let bits = ((info.st_mode & 0o111) != 0 ? "x" : "-") + ((info.st_mode & 0o022) != 0 ? "w" : "-")
                switch info.st_mode & S_IFMT {
                case S_IFLNK: put("L\0\(next)\0\(try FileManager.default.destinationOfSymbolicLink(atPath: full.path))\0")
                case S_IFDIR: put("D\0\(next)\0\(bits)\0"); try walk(next)
                case S_IFREG: put("F\0\(next)\0\(bits)\0"); hash.update(data: try Data(contentsOf: full)); put("\0")
                default: put("O\0\(next)\0")
                }
            }
        }
        try walk("")
        return hash.finalize().map { String(format: "%02x", $0) }.joined()
    }
    /// The first format (contents of regular files only), which bundles built before piagent-bundle#12 carry.
    /// Accepted until those are rebuilt; the v2 digest is what a new bundle pins.
    public static func hashDirectoryLegacy(_ dir: URL) throws -> String {
        var hash = SHA256()
        func walk(_ rel: String) throws {
            let abs = rel.isEmpty ? dir : dir.appendingPathComponent(rel)
            for name in try FileManager.default.contentsOfDirectory(atPath: abs.path).sorted(by: { $0.utf16.lexicographicallyPrecedes($1.utf16) }) {
                let next = rel.isEmpty ? name : rel + "/" + name
                let type = try FileManager.default.attributesOfItem(atPath: dir.appendingPathComponent(next).path)[.type] as? FileAttributeType
                if type == .typeDirectory { try walk(next) }
                else if type == .typeRegular {
                    hash.update(data: Data((next + "\0").utf8)); hash.update(data: try Data(contentsOf: dir.appendingPathComponent(next))); hash.update(data: Data([0]))
                }
            }
        }
        try walk("")
        return hash.finalize().map { String(format: "%02x", $0) }.joined()
    }
    /// Pi's own environment and flags for the company runtime. Same list as `launchPlan` in
    /// piagent-bundle `src/launcher.mjs` (fix/security-bundle): nothing a project carries adds code
    /// or prompts, and Pi makes no network call (catalog, version check, telemetry, fd/rg download).
    static let piEnvironment = ["PI_OFFLINE": "1", "PI_TELEMETRY": "0", "PI_SKIP_VERSION_CHECK": "1"]
    static let piFlags = ["--no-extensions", "--no-approve", "--no-skills", "--no-prompt-templates", "--offline"]
    /// realpath(3), as the provider compares the broker (Foundation's resolvingSymlinksInPath drops `/private`).
    static func realPath(_ url: URL) -> String? {
        var buffer = [CChar](repeating: 0, count: Int(PATH_MAX))
        return realpath(url.path, &buffer) == nil ? nil : String(cString: buffer)
    }
    static func hex(_ file: URL) throws -> String { SHA256.hash(data: try Data(contentsOf: file)).map { String(format: "%02x", $0) }.joined() }

    /// Problems of `parts` against what is on disk (empty = every part matches).
    static func problems(bundle: URL, parts pinned: [String: (path: String, sha256: String)], piVersion version: String) -> [String] {
        var out: [String] = []
        if version != piVersion { out.append("pi-version:" + version) }
        for name in parts {
            guard let part = pinned[name] else { out.append("missing:" + name); continue }
            let dir = bundle.appendingPathComponent(part.path)
            guard FileManager.default.fileExists(atPath: dir.path) else { out.append("absent:" + name); continue }
            if let found = try? hashDirectory(dir), found == part.sha256 {} else if let old = try? hashDirectoryLegacy(dir), old == part.sha256 {} else { out.append("hash-mismatch:" + name) }
        }
        return out
    }
    static func pinnedParts(_ object: [String: Any]) -> [String: (path: String, sha256: String)] {
        var out: [String: (path: String, sha256: String)] = [:]
        for (name, value) in object["parts"] as? [String: Any] ?? [:] {
            guard let part = value as? [String: Any], let path = part["path"] as? String, let sha = part["sha256"] as? String,
                  !path.isEmpty, !path.hasPrefix("/"), !path.split(separator: "/").contains(".."), sha.count == 64 else { continue }
            out[name] = (path, sha)
        }
        return out
    }

    /// The binding to write: the bundle's own manifest, re-checked against the
    /// disk, plus the broker this app ships. Nothing is read from PATH.
    public static func prepare(root: URL, connection: StudioProfile, manifest: StudioManifest, helper: URL, search: BundleSearch? = nil) throws -> StudioConfigurationPlan {
        try manifest.validate(profile: connection)
        guard connection.credentialMode == .managed, manifest.harness != nil, helper.isFileURL,
              FileManager.default.isExecutableFile(atPath: helper.path) else { throw StudioError.permissionDenied }
        guard let bundle = locateBundle(root: root, search: search),
              let data = try? Data(contentsOf: bundle.appendingPathComponent("manifest.json")),
              let object = try? StudioClientConfiguration.object(data), object["schema"] as? Int == 1 else { throw StudioPiRuntimeError.bundleMissing }
        let pinned = pinnedParts(object)
        let issues = problems(bundle: bundle, parts: pinned, piVersion: object["piVersion"] as? String ?? "")
        guard issues.isEmpty else { throw StudioPiRuntimeError.bundleMismatch(issues) }
        let launcher = try launcherBinding(bundle: bundle, pi: pinned["pi"]!.path, node: nil)
        guard let brokerPath = realPath(helper) else { throw StudioPiRuntimeError.bindingChanged }
        let broker = URL(fileURLWithPath: brokerPath)
        var binding: [String: Any] = ["schema_version": 1, "runtime": "pi", "profile_id": connection.id, "origin": connection.origin.value,
            "pi_version": piVersion, "bundle_version": object["bundleVersion"] as? String ?? "", "bundle_root": bundle.path,
            "parts": pinned.mapValues { ["path": $0.path, "sha256": $0.sha256] },
            "manifest_sha256": try hex(bundle.appendingPathComponent("manifest.json")), "entrypoint": launcher.entrypoint.path, "entrypoint_sha256": launcher.entrypointSHA256,
            "broker": broker.path, "broker_sha256": try hex(broker),
            "agent_dir": agentDirectory(root: root).path, "session_dir": sessionDirectory(root: root).path,
            "configuration_revision": manifest.revision]
        if let node = launcher.interpreter, let sha = launcher.interpreterSHA256 { binding["node"] = node.path; binding["node_sha256"] = sha }
        let file = bindingURL(root: root)
        return StudioConfigurationPlan(edits: [.init(file: file, before: try StudioClientConfiguration.read(file), after: try StudioClientConfiguration.encoded(binding))], tool: .pi, profileID: connection.id)
    }
    static func launcherBinding(bundle: URL, pi: String, node: URL?) throws -> StudioRuntimeBinding {
        try StudioRuntimeBinding.resolve(entrypoint: bundle.appendingPathComponent(pi + "/bin/pi"), node: node)
    }

    /// Same consent step as the Piagent path, against this runtime's binding.
    public static func authorize(root: URL, profileID: String) async throws {
        try await StudioManagedConfiguration.authorize(directory: root, profileID: profileID, binding: bindingName)
    }

    /// Checks everything the binding pins, then returns the argv and the whole
    /// environment of the process. The environment is closed (`env -i`): no key,
    /// token or inherited variable, only these paths.
    public static func launch(root: URL, profileID: String) throws -> (executable: String, arguments: [String], environment: [String: String]) {
        guard let data = try? StudioClientConfiguration.read(bindingURL(root: root)) else { throw StudioPiRuntimeError.bindingMissing }
        let object = try StudioClientConfiguration.object(data)
        guard object["runtime"] as? String == "pi", object["profile_id"] as? String == profileID,
              let bundleRoot = object["bundle_root"] as? String, let entry = object["entrypoint"] as? String, let entryHash = object["entrypoint_sha256"] as? String,
              let broker = object["broker"] as? String, let brokerHash = object["broker_sha256"] as? String,
              let agent = object["agent_dir"] as? String, let sessions = object["session_dir"] as? String,
              agent == agentDirectory(root: root).path, sessions == sessionDirectory(root: root).path else { throw StudioPiRuntimeError.bindingMissing }
        let bundle = URL(fileURLWithPath: bundleRoot)
        guard acceptedLocation(bundle, root: root) else { throw StudioPiRuntimeError.bindingChanged }
        let pinned = pinnedParts(object)
        // `doctor --expect`: the manifest itself is pinned too, so a manifest rewritten with the files it describes does not verify.
        var issues = (try? hex(bundle.appendingPathComponent("manifest.json"))) == object["manifest_sha256"] as? String ? [] : ["manifest-digest-mismatch"]
        issues += problems(bundle: bundle, parts: pinned, piVersion: object["pi_version"] as? String ?? "")
        guard issues.isEmpty else { throw StudioPiRuntimeError.bundleMismatch(issues) }
        guard let launcher = try? launcherBinding(bundle: bundle, pi: pinned["pi"]?.path ?? "", node: (object["node"] as? String).map { URL(fileURLWithPath: $0) }),
              launcher.entrypoint.path == entry, launcher.entrypointSHA256 == entryHash, launcher.interpreterSHA256 == object["node_sha256"] as? String,
              broker.hasPrefix("/"), realPath(URL(fileURLWithPath: broker)) == broker,
              (try? hex(URL(fileURLWithPath: broker))) == brokerHash else { throw StudioPiRuntimeError.bindingChanged }
        try StudioCLIProfiles.privateDirectory(root)
        try StudioCLIProfiles.privateDirectory(URL(fileURLWithPath: agent)); try StudioCLIProfiles.privateDirectory(URL(fileURLWithPath: sessions))
        let part = { (name: String) in bundle.appendingPathComponent(pinned[name]!.path).path }
        let environment = ["PATH": "/usr/bin:/bin", "TERM": "xterm-256color", "LANG": "en_US.UTF-8",
                           "PI_CODING_AGENT_DIR": agent, "PI_CODING_AGENT_SESSION_DIR": sessions,
                           "AGENT_WATCH_MANAGED_BINDING": bindingURL(root: root).path].merging(piEnvironment) { $1 }
        return (launcher.executable.path, launcher.prefixArguments + piFlags + ["-e", part("harness"), "-e", part("sandbox"), "-e", part("provider"), "-e", "builtin:mcp"], environment)
    }

    /// The bundle version the `pi` binding of `profileID` pins, for the broker to send with `start`.
    /// Nil when there is no such binding (Piagent), so that path sends nothing extra.
    public static func pinnedBundleVersion(root: URL, profileID: String) -> String? {
        guard let data = try? StudioClientConfiguration.read(bindingURL(root: root)), let object = try? StudioClientConfiguration.object(data),
              object["runtime"] as? String == "pi", object["profile_id"] as? String == profileID,
              let version = object["bundle_version"] as? String, (1...64).contains(version.utf8.count),
              version.utf8.allSatisfy({ (48...57).contains($0) || (65...90).contains($0) || (97...122).contains($0) || [0x2e, 0x2b, 0x2d].contains($0) }) else { return nil }
        return version
    }
    /// Studio asks for Piagent again: the Pi binding goes, so a later broker sends no bundle version.
    public static func retire(root: URL) { try? FileManager.default.removeItem(at: bindingURL(root: root)) }

    /// "Sửa cài đặt": a one-use Terminal script that runs the install command in the member's own login shell
    /// (their Node, their npm prefix), visibly. Agent Watch itself runs no npm.
    public static func repairTerminal(repair: Bool, launchDirectory: URL = StudioTerminalCommand.directory) throws -> StudioTerminalCommand {
        try StudioCLIProfiles.privateDirectory(launchDirectory)
        let target = launchDirectory.appendingPathComponent(UUID().uuidString.lowercased() + ".command")
        let quote = StudioClientConfiguration.shellQuote
        let inner = "\(installCommand(repair: repair)); echo; echo 'Xong. Quay lại Agent Watch và bấm Đồng bộ.'; read -k 1 '?Nhấn phím bất kỳ để đóng.'"
        let script = "#!/bin/sh\numask 077\n/bin/rm -f -- \(quote(target.path))\nexec /bin/zsh -lic \(quote(inner))\n"
        try Data(script.utf8).write(to: target, options: [.withoutOverwriting])
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: target.path)
        return StudioTerminalCommand(url: target)
    }

    public static func terminal(root: URL, project: URL, profileID: String, launchDirectory: URL = StudioTerminalCommand.directory) throws -> StudioTerminalCommand {
        guard project.isFileURL, (try? project.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true else { throw StudioCLIError.invalidArguments }
        let plan = try launch(root: root, profileID: profileID)
        try StudioCLIProfiles.privateDirectory(launchDirectory)
        let target = launchDirectory.appendingPathComponent(UUID().uuidString.lowercased() + ".command")
        let quote = StudioClientConfiguration.shellQuote
        let env = plan.environment.sorted { $0.key < $1.key }.map { quote($0.key + "=" + $0.value) }.joined(separator: " ")
        let script = "#!/bin/sh\numask 077\n/bin/rm -f -- \(quote(target.path))\ncd \(quote(project.resolvingSymlinksInPath().path)) || exit 1\nexec /usr/bin/env -i \(env) \(([plan.executable] + plan.arguments).map(quote).joined(separator: " "))\n"
        try Data(script.utf8).write(to: target, options: [.withoutOverwriting])
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: target.path)
        return StudioTerminalCommand(url: target)
    }
}
