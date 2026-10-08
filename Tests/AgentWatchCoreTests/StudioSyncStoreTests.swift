import XCTest
@testable import AgentWatchCore

private actor SyncTransport: StudioHTTPTransport {
    var headers: [String?] = []
    func conditionalHeaders() -> [String?] { headers }
    var failure = false
    var pause = false
    var responseWaiter: CheckedContinuation<Void, Never>?
    var requestWaiter: CheckedContinuation<Void, Never>?
    var entered = false
    func setFailure() { failure = true }
    func hold() { pause = true; entered = false }
    func waitForRequest() async {
        if entered { return }
        await withCheckedContinuation { requestWaiter = $0 }
    }
    func release() { pause = false; responseWaiter?.resume(); responseWaiter = nil }
    func send(_ request: URLRequest, origin: StudioOrigin) async throws -> StudioHTTPResponse {
        headers.append(request.value(forHTTPHeaderField: "If-None-Match"))
        entered = true; requestWaiter?.resume(); requestWaiter = nil
        if pause { await withCheckedContinuation { responseWaiter = $0 } }
        if failure { throw StudioError.offline }
        return .init(status: 200, body: Data("""
        {"schema_version":1,"revision":"\(String(repeating: "a", count: 64))","org_id":"00000000-0000-4000-8000-000000000001","user":{"id":"00000000-0000-4000-8000-000000000002","display_name":"Fixture","role":"member","active":true,"version":1,"team_id":"00000000-0000-4000-8000-000000000003","team_name":"Fixture"},"key_id":"00000000-0000-4000-8000-000000000004","expires_at":"2099-01-01T00:00:00Z","refresh_seconds":300,"models":[],"codex_catalog":{"models":[]}}
        """.utf8))
    }
}
@MainActor private final class SyncSettings: StudioSettingsStorage {
    var profile: StudioProfile?
    init() throws {
        let origin = try StudioOrigin("https://studio.test")
        profile = try StudioProfile(origin: origin, id: origin.profileID(orgID: UUID(uuidString: "00000000-0000-4000-8000-000000000001")!, ownerID: UUID(uuidString: "00000000-0000-4000-8000-000000000002")!))
    }
    func load() -> StudioProfile? { profile }
    func save(_ profile: StudioProfile?) { self.profile = profile }
}
@MainActor private final class SyncKeys: StudioKeyStorage {
    func load(profileID: String) -> String? { "fixture-key" }
    func save(_ key: String, profileID: String) {}
    func delete(profileID: String) {}
}
/// A key macOS will only hand over after the member allows it once.
@MainActor private final class ApprovalKeys: StudioKeyStorage {
    var approved = false, prompts = 0
    func load(profileID: String) throws -> String? { try load(profileID: profileID, allowInteraction: false) }
    func load(profileID: String, allowInteraction: Bool) throws -> String? {
        if allowInteraction { prompts += 1; approved = true }
        guard approved else { throw StudioError.keychainApprovalRequired }
        return "fixture-key"
    }
    func save(_ key: String, profileID: String) {}
    func delete(profileID: String) {}
}
@MainActor private final class SyncFixture {
    let suite = "studio-sync-test-" + UUID().uuidString
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    let defaults: UserDefaults
    let transport = SyncTransport()
    let store: StudioSyncStore
    init() throws {
        defaults = UserDefaults(suiteName: suite)!
        store = StudioSyncStore(defaults: defaults, client: StudioClient(transport: transport), settings: try SyncSettings(), keys: SyncKeys())
        store.directories = Dictionary(uniqueKeysWithValues: StudioSyncTarget.allCases.map { ($0.rawValue, root.appendingPathComponent($0.rawValue).path) })
        store.selected = [.claude]
    }
    func clean() { store.stop(); defaults.removePersistentDomain(forName: suite); try? FileManager.default.removeItem(at: root) }
}
final class StudioSyncStoreTests: XCTestCase {
    @MainActor func testKeychainApprovalIsReportedAndAllowingItSynchronizesAtOnce() async throws {
        let suite = "studio-keychain-" + UUID().uuidString, defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let keys = ApprovalKeys(), transport = SyncTransport()
        let store = StudioSyncStore(defaults: defaults, client: StudioClient(transport: transport), settings: try SyncSettings(), keys: keys)
        store.selected = [.claude]; store.directories = ["claude": root.path]; store.enabled = true
        await store.synchronize()
        XCTAssertTrue(store.needsKeychainApproval, "The background sync cannot read the key without macOS asking")
        XCTAssertEqual(keys.prompts, 0, "The background sync never shows macOS's prompt itself")
        let allowed = await store.authorizeKeychain()
        XCTAssertTrue(allowed); XCTAssertEqual(keys.prompts, 1)
        XCTAssertFalse(store.needsKeychainApproval); XCTAssertNotNil(store.lastChecked)
        let headers = await transport.conditionalHeaders()
        XCTAssertEqual(headers.count, 1, "Allowing synchronizes at once")
    }
    @MainActor func testBackgroundSyncCoversInactiveSlotWithoutChangingSelectionOrSharingETag() async throws {
        let suite = "studio-background-slots-" + UUID().uuidString, defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let settings = StudioPreferences(defaults: defaults), first = try XCTUnwrap(SyncSettings().profile)
        let second = try StudioProfile(origin: first.origin, id: String(repeating: "b", count: 64), connectionID: first.id)
        settings.save(first); settings.save(second)
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let transport = SyncTransport()
        let store = StudioSyncStore(defaults: defaults, client: StudioClient(transport: transport), settings: settings, keys: SyncKeys())
        store.selected = [.claude]; store.directories = ["claude": root.path]; store.enabled = true
        settings.save(first); store.activateProfile()
        XCTAssertFalse(store.enabled, "First slot's toggle must not disable the second slot")
        await store.synchronizeSavedProfiles()
        XCTAssertEqual(try settings.load(), first); XCTAssertTrue(store.results.isEmpty); XCTAssertNil(store.keyInfo)
        var headers = await transport.conditionalHeaders()
        XCTAssertEqual(headers.count, 1); XCTAssertNil(headers[0])
        await store.synchronizeSavedProfiles()
        headers = await transport.conditionalHeaders()
        XCTAssertEqual(headers.count, 2); XCTAssertNotNil(headers[1], "The inactive slot retains its own ETag")
        // The selected slot must not use the other slot's ETag.
        store.selected = [.codex]; store.directories = ["codex": root.appendingPathComponent("codex").path]
        await store.synchronize()
        headers = await transport.conditionalHeaders()
        XCTAssertEqual(headers.count, 3); XCTAssertNil(headers[2])
        settings.save(second); settings.save(nil); settings.save(first)
        await store.synchronizeSavedProfiles()
        headers = await transport.conditionalHeaders()
        XCTAssertEqual(headers.count, 3, "Removed slots cannot be refreshed by old workers")
    }
    @MainActor func testSwitchingCredentialClearsETagAndKeepsIndependentPreferences() async throws {
        let suite = "studio-sync-slots-" + UUID().uuidString, defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let settings = StudioPreferences(defaults: defaults), first = try XCTUnwrap(SyncSettings().profile)
        let second = try StudioProfile(origin: first.origin, id: String(repeating: "b", count: 64), connectionID: first.id, keyID: UUID(), credentialMode: .managed)
        settings.save(first)
        let transport = SyncTransport(), store = StudioSyncStore(defaults: defaults, client: StudioClient(transport: transport), settings: settings, keys: SyncKeys())
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        store.selected = [.claude]; store.directories = ["claude": root.path]; store.enabled = true
        await store.synchronize()
        XCTAssertNotNil(store.keyInfo); XCTAssertNotNil(store.lastChecked)
        await transport.hold()
        let pending = Task { await store.synchronize() }
        await transport.waitForRequest()
        settings.save(second); store.activateProfile()
        XCTAssertNil(store.keyInfo); XCTAssertNil(store.lastChecked); XCTAssertTrue(store.selected.isEmpty)
        XCTAssertTrue(store.directories.isEmpty); XCTAssertFalse(store.enabled)
        store.selected = [.pi, .piagent];
        settings.save(first); store.activateProfile()
        settings.save(second); store.activateProfile()
        XCTAssertEqual(store.selected, [.piagent], "Managed keys never import into plain Pi")
        store.selected = [.piagent]; store.directories = ["piagent": root.appendingPathComponent("managed").path]
        await transport.release(); await pending.value
        XCTAssertTrue(store.results.isEmpty); XCTAssertNil(store.lastError)
        settings.save(first); store.activateProfile()
        XCTAssertEqual(store.selected, [.claude]); XCTAssertEqual(store.directories["claude"], root.path); XCTAssertTrue(store.enabled)
        XCTAssertEqual(store.keyInfo?.keyID.uuidString.lowercased(), "00000000-0000-4000-8000-000000000004", "Only this slot's saved key facts may be restored")
        XCTAssertNil(store.lastChecked, "Restored metadata is not a fresh verification")
        let restored = StudioSyncStore(defaults: defaults, client: StudioClient(transport: transport), settings: settings, keys: SyncKeys())
        XCTAssertEqual(restored.selected, [.claude]); XCTAssertTrue(restored.enabled)
    }
    @MainActor func testManagedKeyDropsToolsTickedBeforeTheModeWasKnown() async throws {
        let suite = "studio-sync-managed-" + UUID().uuidString, defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let settings = StudioPreferences(defaults: defaults), first = try XCTUnwrap(SyncSettings().profile)
        let managed = try StudioProfile(origin: first.origin, id: String(repeating: "c", count: 64), connectionID: first.id, keyID: UUID(), credentialMode: .managed)
        settings.save(managed)
        let store = StudioSyncStore(defaults: defaults, client: StudioClient(transport: SyncTransport()), settings: settings, keys: SyncKeys())
        store.activateProfile()
        store.selected = [.pi, .piagent]
        await store.synchronize()
        XCTAssertEqual(store.selected, [.piagent], "Plain Pi shares the Piagent folder and must not block the company import")
        XCTAssertFalse(store.results.contains { $0.target == .pi })
    }

    @MainActor func testReconnectedCompanyKeyCanRestoreTheDisconnectedKeysPiagentImport() async throws {
        let suite = "studio-sync-orphan-" + UUID().uuidString, defaults = UserDefaults(suiteName: suite)!
        let root = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".cache/watch-orphan-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let receipt = StudioManagedConfiguration.receiptURL(directory: root)
        defer { defaults.removePersistentDomain(forName: suite); try? FileManager.default.removeItem(at: root); try? FileManager.default.removeItem(at: receipt) }
        let settings = StudioPreferences(defaults: defaults), first = try XCTUnwrap(SyncSettings().profile)
        let fresh = try StudioProfile(origin: first.origin, id: String(repeating: "d", count: 64), connectionID: first.id, keyID: UUID(), credentialMode: .managed)
        // The disconnected key's import: only Watch's managed binding file.
        let binding = root.appendingPathComponent("agent-watch-managed.json")
        let edit = StudioConfigurationEdit(file: binding, before: nil, after: Data(#"{"profile_id":"old"}"#.utf8))
        try StudioClientConfiguration.apply(StudioConfigurationPlan(edits: [edit], tool: .pi, profileID: String(repeating: "e", count: 64)), receipt: receipt)
        settings.save(fresh)
        let store = StudioSyncStore(defaults: defaults, client: StudioClient(transport: SyncTransport()), settings: settings, keys: SyncKeys())
        store.activateProfile(); store.directories = ["piagent": root.path, "pi": root.path]; store.selected = [.piagent]
        store.restore(.piagent)
        XCTAssertEqual(store.status, "Đã khôi phục cấu hình Piagent.")
        XCTAssertFalse(FileManager.default.fileExists(atPath: binding.path), "Restore returns the folder to its state before Agent Watch")
        XCTAssertFalse(FileManager.default.fileExists(atPath: receipt.path))
        XCTAssertTrue(store.selected.isEmpty)
    }
    @MainActor func testChangedDirectoryAndSelectionInvalidateOldTargetResults() async throws {
        let f = try SyncFixture(); defer { f.clean() }
        await f.store.synchronize()
        XCTAssertEqual(f.store.results.count, 1)
        XCTAssertFalse(f.store.results[0].success, "No granted model must not be labelled ready")
        let same = f.store.selected; f.store.selected = same
        XCTAssertEqual(f.store.results.count, 1, "Unchanged selection retains the verified outcome")
        f.store.directories["claude"] = f.root.appendingPathComponent("new-claude").path
        XCTAssertTrue(f.store.results.isEmpty, "An outcome for the old directory cannot describe the new directory")
        await f.store.synchronize()
        XCTAssertEqual(f.store.results.count, 1)
        f.store.selected.insert(.codex)
        XCTAssertTrue(f.store.results.isEmpty)
        let reloaded = StudioSyncStore(defaults: f.defaults, client: StudioClient(transport: f.transport), settings: try SyncSettings(), keys: SyncKeys())
        XCTAssertEqual(reloaded.selected, [.claude, .codex])
        XCTAssertEqual(reloaded.directories, f.store.directories)
    }
    @MainActor func testOfflineRefreshIsMarkedUnverifiedAndResetClearsItsTimestamp() async throws {
        let f = try SyncFixture(); defer { f.clean() }
        await f.store.synchronize()
        XCTAssertNotNil(f.store.lastChecked)
        await f.transport.setFailure()
        await f.store.synchronize()
        XCTAssertNotNil(f.store.lastError, "Cached per-tool results cannot be presented as current after a failed refresh")
        f.store.reset()
        XCTAssertNil(f.store.lastChecked); XCTAssertNil(f.store.lastError)
        XCTAssertTrue(f.store.results.isEmpty); XCTAssertFalse(f.store.enabled)
    }
    @MainActor func testSelectionChangedDuringManifestReadRejectsLateResult() async throws {
        let f = try SyncFixture(); defer { f.clean() }
        await f.transport.hold()
        let work = Task { await f.store.synchronize() }
        await f.transport.waitForRequest()
        f.store.selected = [.codex]
        await f.transport.release(); await work.value
        XCTAssertTrue(f.store.results.isEmpty)
        XCTAssertNil(f.store.lastChecked)
        XCTAssertFalse(FileManager.default.fileExists(atPath: f.root.path), "Cancelled selection must not write tool configuration")
        await f.store.synchronize()
        XCTAssertEqual(f.store.results.map(\.target), [.codex])
    }
    @MainActor func testDisconnectDuringManifestReadCannotRepopulateStatus() async throws {
        let f = try SyncFixture(); defer { f.clean() }
        await f.transport.hold()
        let work = Task { await f.store.synchronize() }
        await f.transport.waitForRequest()
        f.store.reset()
        await f.transport.release(); await work.value
        XCTAssertTrue(f.store.results.isEmpty); XCTAssertNil(f.store.lastChecked)
        XCTAssertNil(f.store.lastError); XCTAssertFalse(f.store.busy)
        XCTAssertEqual(f.store.status, "Đã ngắt đồng bộ Studio.")
    }
}
