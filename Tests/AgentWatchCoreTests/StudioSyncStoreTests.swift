import XCTest
@testable import AgentWatchCore

private actor SyncTransport: StudioHTTPTransport {
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
        XCTAssertEqual(Set(f.defaults.stringArray(forKey: "studio.sync.targets") ?? []), ["claude", "codex"])
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
