import Foundation
@testable import AgentWatchCore

@MainActor private final class ProbeSettings: StudioSettingsStorage {
    var profile: StudioProfile?
    init(_ profile: StudioProfile) { self.profile = profile }
    func load() throws -> StudioProfile? { profile }
    func save(_ profile: StudioProfile?) { self.profile = profile }
}
@MainActor private final class ProbeKeys: StudioKeyStorage {
    let key: String
    init(_ key: String) { self.key = key }
    func load(profileID: String) throws -> String? { key }
    func save(_ key: String, profileID: String) throws { throw StudioError.storage }
    func delete(profileID: String) throws { throw StudioError.storage }
}
@MainActor private final class LifecycleKeys: StudioKeyStorage {
    var value: String?
    init(_ key: String) { value = key }
    func load(profileID: String) throws -> String? { value }
    func save(_ key: String, profileID: String) throws { value = key }
    func delete(profileID: String) throws { value = nil }
}

// Test-only entry point: no production environment-key fallback. The Go fixture
// supplies a temporary database key and confines this process to its gateway.
@main struct StudioCLIProbe {
    @MainActor static func main() async {
        do {
            let env = ProcessInfo.processInfo.environment
            guard let raw = env["STUDIO_FIXTURE_ORIGIN"], raw.hasPrefix("http://127.0.0.1:"),
                  let key = env["STUDIO_FIXTURE_KEY"], let directory = env["STUDIO_FIXTURE_DIRECTORY"],
                  let provider = env["STUDIO_FIXTURE_PROVIDER"].flatMap(StudioCLIProvider.init(rawValue:)),
                  let binary = env["STUDIO_FIXTURE_BINARY"] else { throw StudioCLIError.invalidArguments }
            let origin = try StudioOrigin(raw), result = try await StudioClient().connect(origin: origin, key: key)
            guard case .available(let models) = result.models, let model = models.first(where: { $0.id == "studio-model" }) else { throw StudioError.invalidResponse }
            let identity = try StudioProfile(origin: origin, id: origin.profileID(orgID: result.identity.orgID, ownerID: result.identity.user.id))
            let root = URL(fileURLWithPath: directory, isDirectory: true)
            let resume = env["STUDIO_FIXTURE_RESUME"].flatMap(UUID.init(uuidString:))
            if CommandLine.arguments.contains("--keep-cli") || CommandLine.arguments.contains("--close-cli") {
                let directory = root.appendingPathComponent("profiles", isDirectory: true)
                let registry = StudioProcessRegistry(directory: directory)
                // This is a different process from the launcher. Acquisition
                // while the actual CLI is awaiting a response proves exec did
                // not retain the launch lock or require a running GUI.
                let before = try registry.withLaunchLock(connection: identity) { registry.snapshot(connection: identity) }
                guard !before.incomplete, before.entries.count == 1, before.entries[0].state == .running,
                      before.entries[0].process.provider == provider else { throw StudioCLIError.processFailed }
                let profile = try StudioCLIProfiles.prepare(connection: identity, provider: provider, directory: directory)
                let manifest = profile.root.appendingPathComponent("profile.json")
                let originalManifest = try Data(contentsOf: manifest)
                let keys = LifecycleKeys(key), settings = ProbeSettings(identity)
                let store = StudioConnectionStore(keys: keys, settings: settings, cache: StudioDashboardCache(directory: root.appendingPathComponent("cache")))
                let choice: StudioDisconnectChoice = CommandLine.arguments.contains("--keep-cli") ? .keepCLI : .closeCLI
                let disconnected = try await StudioDisconnect.perform(store: store, expected: identity, choice: choice, registry: registry)
                guard store.profile == nil, keys.value == nil, settings.profile == nil,
                      !disconnected.incomplete, disconnected.unverified == 0,
                      disconnected.closed == (choice == .closeCLI ? 1 : 0),
                      disconnected.remaining == (choice == .keepCLI ? 1 : 0) else { throw StudioCLIError.processFailed }
                await store.connect(origin: origin.value, key: key)
                guard store.state == .connected, store.profile == identity, keys.value == key,
                      try StudioCLIProfiles.prepare(connection: identity, provider: provider, directory: directory) == profile,
                      try Data(contentsOf: manifest) == originalManifest else { throw StudioCLIError.processFailed }
                print("PASS active native CLI disconnect choice, saved-key removal, available launch lock and stable reconnect profile")
                return
            }
            if CommandLine.arguments.contains("--logs") {
                let registry = StudioProcessRegistry(directory: root.appendingPathComponent("profiles", isDirectory: true))
                try registry.withLaunchLock(connection: identity) {
                    let processes = registry.snapshot(connection: identity)
                    guard !processes.incomplete, processes.entries.count == 1,
                          processes.entries.allSatisfy({ $0.state == .finished && $0.process.provider == provider }) else { throw StudioCLIError.processFailed }
                }
                let snapshot = await StudioLocalLogReader(directory: root.appendingPathComponent("profiles", isDirectory: true)).read(connection: identity, range: Date().addingTimeInterval(-3600)..<Date())
                guard snapshot.issues.isEmpty, snapshot.sessions.count == 1,
                      let session = snapshot.sessions.first, session.provider == provider,
                      session.sessionID.lowercased() == resume?.uuidString.lowercased(),
                      session.knownTokens == 30, !session.partial,
                      !String(describing: snapshot).contains(key) else {
                    print("FAIL registered logs: sessions=\(snapshot.sessions.count), known=\(snapshot.sessions.first?.knownTokens ?? -1), partial=\(snapshot.partial), issues=\(snapshot.issues.map(\.rawValue))")
                    throw StudioCLIError.processFailed
                }
                guard let digest = StudioSessionComparison.digest(sessionID: session.sessionID) else { throw StudioError.invalidResponse }
                let report = try await StudioClient().sessionUsage(origin: origin, key: key, identity: result.identity, provider: provider, digest: digest, range: snapshot.from..<snapshot.to)
                let comparison = StudioSessionComparison.compare(local: session, report: report, coveragePartial: !snapshot.issues.isEmpty)
                guard comparison.status == .matched, comparison.serverTokens?.value == "30", comparison.serverRequests?.value == "2" else {
                    print("FAIL native reconciliation: \(comparison.reason.rawValue)")
                    throw StudioCLIError.processFailed
                }
                print("PASS registered native logs: one persisted session, 30 local fixture tokens matched to two confirmed Studio requests; no terminal environment or credential content")
                return
            }
            var args = [provider.rawValue, "--profile", identity.id, "--model", model.id, "--project", root.appendingPathComponent("project").path, "--binary", binary, "--print", resume == nil ? "Return STUDIO_FIXTURE_OK." : "Continue with STUDIO_RESUME_QUESTION."]
            if let resume { args += ["--resume", resume.uuidString] }
            if CommandLine.arguments.contains("--check") { args += ["--check"] }
            let status = await StudioRunCommand(arguments: args, settings: ProbeSettings(identity), keys: ProbeKeys(key), client: StudioClient(), directory: root.appendingPathComponent("profiles", isDirectory: true)).run()
            if status == 0 { print("PASS keyless native configuration preflight; no inference") }
            exit(status)
        } catch {
            // Never dump native output, config, request data or keys.
            let message = (error as? StudioCLIError)?.rawValue ?? (error as? StudioError)?.rawValue ?? "fixtureFailed"
            FileHandle.standardError.write(Data(("launcher fixture: " + message + "\n").utf8))
            exit(1)
        }
    }
}
