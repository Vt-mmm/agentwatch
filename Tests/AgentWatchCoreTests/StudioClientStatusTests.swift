import XCTest
@testable import AgentWatchCore

private actor StatusTransport: StudioHTTPTransport {
    var posts: [Data] = []
    var postStatus = 204
    func setPostStatus(_ value: Int) { postStatus = value }
    func send(_ request: URLRequest, origin: StudioOrigin) async throws -> StudioHTTPResponse {
        if request.httpMethod == "POST" {
            posts.append(request.httpBody ?? Data())
            return .init(status: postStatus, contentType: "", body: Data())
        }
        return .init(status: 200, body: Data("""
        {"schema_version":1,"revision":"\(String(repeating: "b", count: 64))","org_id":"00000000-0000-4000-8000-000000000001","user":{"id":"00000000-0000-4000-8000-000000000002","display_name":"Fixture","role":"member","active":true,"version":1,"team_id":"00000000-0000-4000-8000-000000000003","team_name":"Fixture"},"key_id":"00000000-0000-4000-8000-000000000004","key_label":"MacBook","key_prefix":"as_live_00000000","expires_at":"2099-01-01T00:00:00Z","refresh_seconds":300,"models":[],"codex_catalog":{"models":[]}}
        """.utf8))
    }
}
@MainActor private final class StatusSettings: StudioSettingsStorage {
    var profile: StudioProfile?
    init() throws {
        let origin = try StudioOrigin("https://studio.test")
        profile = try StudioProfile(origin: origin, id: origin.profileID(orgID: UUID(uuidString: "00000000-0000-4000-8000-000000000001")!, ownerID: UUID(uuidString: "00000000-0000-4000-8000-000000000002")!))
    }
    func load() -> StudioProfile? { profile }
    func save(_ profile: StudioProfile?) { self.profile = profile }
}
@MainActor private final class StatusKeys: StudioKeyStorage {
    func load(profileID: String) -> String? { "fixture-key" }
    func save(_ key: String, profileID: String) {}
    func delete(profileID: String) {}
}

final class StudioClientStatusTests: XCTestCase {
    func testReportCarriesCodesAndVersionsOnly() throws {
        let failed = StudioSyncResult(target: .codex, count: 2, message: "Permission denied: /Users/someone/.codex", success: false, code: "config_unwritable")
        let report = StudioClientStatusReport.make(installationID: UUID(), appVersion: "0.13.0", appBuild: "130", osVersion: "15.6.1",
            revision: String(repeating: "a", count: 64), autoSync: true, launchAtLogin: "enabled", selected: [.claude, .codex],
            results: [StudioSyncResult(target: .claude, count: 3, message: "ok", success: true), failed],
            cliVersions: ["claude": "2.1.181", "codex": "0.160.0"], syncedAt: Date())
        let json = String(decoding: try report.encoded(), as: UTF8.self)
        XCTAssertFalse(json.contains("/Users"), "Free-form error text must never be sent")
        XCTAssertFalse(json.contains("Permission"))
        XCTAssertEqual(report.tools.map(\.status), ["synced", "failed", "not_selected", "not_selected"])
        XCTAssertEqual(report.tools[0].cli_supported, true)
        XCTAssertEqual(report.tools[1].cli_supported, false)
        XCTAssertEqual(report.tools[1].error_code, "config_unwritable")
        let unselected = try JSONSerialization.jsonObject(with: JSONEncoder().encode(report.tools[2])) as? [String: Any]
        XCTAssertEqual(Set(unselected?.keys ?? [:].keys), ["target", "status"], "Unselected tools carry no details")
        let odd = StudioClientStatusReport.make(installationID: UUID(), appVersion: "v0.13", appBuild: "../x", osVersion: nil, revision: "nope",
            autoSync: false, launchAtLogin: "maybe", selected: [], results: [], cliVersions: [:], syncedAt: nil)
        XCTAssertEqual(odd.app.version, "0.13"); XCTAssertNil(odd.app.build); XCTAssertNil(odd.config_revision)
        XCTAssertEqual(odd.background.launch_at_login, "unavailable")
        XCTAssertEqual(StudioClientStatusReport.number(in: "codex-cli 0.155.1"), "0.155.1")
        XCTAssertEqual(StudioSyncErrorCode.code(for: StudioCLIError.unsupportedVersion, target: .codex), "cli_unsupported_version")
        XCTAssertEqual(StudioSyncErrorCode.code(for: StudioConfigurationError.changed, target: .claude), "config_changed_externally")
    }

    @MainActor func testSyncReportsOnChangeThrottlesRepeatsAndStopsOnOldServers() async throws {
        let suite = "studio-status-test-" + UUID().uuidString
        let defaults = UserDefaults(suiteName: suite)!
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { defaults.removePersistentDomain(forName: suite); try? FileManager.default.removeItem(at: root) }
        let transport = StatusTransport()
        let store = StudioSyncStore(defaults: defaults, client: StudioClient(transport: transport), settings: try StatusSettings(), keys: StatusKeys())
        store.directories = Dictionary(uniqueKeysWithValues: StudioSyncTarget.allCases.map { ($0.rawValue, root.appendingPathComponent($0.rawValue).path) })
        store.selected = [.claude]
        await store.synchronize()
        var posts = await transport.posts
        XCTAssertTrue(posts.isEmpty, "Reporting is opt-in; tests and the CLI never report implicitly")
        XCTAssertEqual(store.keyInfo?.label, "MacBook")
        XCTAssertEqual(store.keyInfo?.prefix, "as_live_00000000")

        store.statusReporting = true
        await store.synchronize()
        posts = await transport.posts
        XCTAssertEqual(posts.count, 1)
        let decoder = JSONDecoder(); decoder.dateDecodingStrategy = .iso8601
        let sent = try decoder.decode(StudioClientStatusReport.self, from: posts[0])
        XCTAssertEqual(sent.tools.first?.error_code, "no_models_granted")
        XCTAssertEqual(sent.installation_id, store.installationID.uuidString.lowercased())
        XCTAssertEqual(store.lastReport?.tools.map(\.status), sent.tools.map(\.status), "The app shows exactly what was sent")

        await store.synchronize()
        posts = await transport.posts
        XCTAssertEqual(posts.count, 1, "An identical report within 30 minutes is not resent")

        store.selected.insert(.codex)
        await transport.setPostStatus(404)
        await store.synchronize()
        XCTAssertEqual(store.reportState, .unsupported)
        store.selected.remove(.codex)
        await store.synchronize()
        posts = await transport.posts
        XCTAssertEqual(posts.count, 2, "An older server is not asked again in this session")

        let reopened = StudioSyncStore(defaults: defaults, client: StudioClient(transport: transport), settings: try StatusSettings(), keys: StatusKeys())
        XCTAssertEqual(reopened.installationID, store.installationID)
        XCTAssertEqual(reopened.keyInfo, store.keyInfo, "Key facts survive relaunch without reading the secret")
        store.reset()
        XCTAssertNil(store.keyInfo)
    }

    func testConnectionCodeSplitsIntoOriginAndKey() {
        let code = StudioConnectionCode.split("  https://Studio.Example.com/#as_live_1234abcd-0000-4000-8000-000000000001_secret\n")
        XCTAssertEqual(code?.origin, "https://studio.example.com"); XCTAssertEqual(code?.key, "as_live_1234abcd-0000-4000-8000-000000000001_secret")
        XCTAssertEqual(StudioConnectionCode.split("http://127.0.0.1:17922#as_live_abc_def")?.origin, "http://127.0.0.1:17922")
        XCTAssertNil(StudioConnectionCode.split("https://studio.example.com"))
        XCTAssertNil(StudioConnectionCode.split("as_live_abc_def"))
        XCTAssertNil(StudioConnectionCode.split("http://studio.example.com#as_live_abc_def"))
        XCTAssertNil(StudioConnectionCode.split("https://studio.example.com#as_live_"))
        XCTAssertNil(StudioConnectionCode.split("https://studio.example.com#as_live_abc def"))
    }

    func testGrantedModelsMissingFromServingListAreReportedAsPaused() {
        let luna = StudioModel(id: "gpt-6-luna", displayName: "GPT-6 Luna", ownedBy: "codex", nativeProtocol: "responses")
        let sonnet = StudioModel(id: "claude-sonnet-5-5", displayName: "Sonnet", ownedBy: "claude", nativeProtocol: "messages")
        XCTAssertEqual(StudioModelAvailability.unavailable(granted: [luna], serving: []).map(\.id), ["gpt-6-luna"])
        XCTAssertEqual(StudioModelAvailability.unavailable(granted: [luna, sonnet], serving: [sonnet]).map(\.id), ["gpt-6-luna"])
        XCTAssertTrue(StudioModelAvailability.unavailable(granted: [luna], serving: [luna]).isEmpty)
        XCTAssertTrue(StudioModelAvailability.unavailable(granted: [], serving: []).isEmpty)
    }

    func testEmployeeStatusPrefersBlockersOverWarnings() {
        let now = Date(timeIntervalSince1970: 1_900_000_000)
        let key = StudioKeyInfo(keyID: UUID(), label: "Mac", prefix: nil, expiresAt: now.addingTimeInterval(3 * 86_400))
        let full = StudioQuotaSummary(period: "day", limit: 100, remaining: 90, endsAt: now)
        let low = StudioQuotaSummary(period: "day", limit: 100, remaining: 10, endsAt: now)
        let empty = StudioQuotaSummary(period: "month", limit: 100, remaining: 0, endsAt: now)
        func eval(_ state: StudioConnectionStore.State = .connected, error: StudioError? = nil, key: StudioKeyInfo? = nil, quota: [StudioQuotaSummary] = [], failed: Int = 0) -> String {
            StudioEmployeeStatus.evaluate(hasProfile: true, state: state, error: error, key: key, quota: quota, failedTools: failed, now: now).title
        }
        XCTAssertEqual(StudioEmployeeStatus.evaluate(hasProfile: false, state: .disconnected, error: nil, key: nil, quota: [], failedTools: 0, now: now).title, "Chưa kết nối")
        XCTAssertEqual(eval(.failed, error: .invalidKey, key: StudioKeyInfo(keyID: UUID(), label: nil, prefix: nil, expiresAt: now.addingTimeInterval(-60))), "Key đã hết hạn")
        XCTAssertEqual(eval(.failed, error: .invalidKey), "Key bị thu hồi hoặc không hợp lệ")
        XCTAssertEqual(eval(.stale, error: .offline, key: key), "Mất kết nối")
        XCTAssertEqual(eval(key: key, quota: [full, empty]), "Hết hạn mức tháng này")
        XCTAssertEqual(eval(key: key, quota: [low]), "Key sắp hết hạn")
        XCTAssertEqual(eval(quota: [low], failed: 1), "Gần hết hạn mức hôm nay")
        XCTAssertEqual(eval(quota: [full], failed: 2), "2 công cụ cần xử lý")
        let ready = StudioEmployeeStatus.evaluate(hasProfile: true, state: .connected, error: nil, key: nil, quota: [full], failedTools: 0, now: now)
        XCTAssertEqual(ready.title, "Sẵn sàng"); XCTAssertEqual(ready.detail, "Còn 90% hạn mức hôm nay"); XCTAssertEqual(ready.tone, .ok)
    }
}
