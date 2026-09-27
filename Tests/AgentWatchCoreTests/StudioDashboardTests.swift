import XCTest
@testable import AgentWatchCore

private let dashboardOwner = UUID(uuidString: "00000000-0000-4000-8000-000000000002")!
private let dashboardOrg = UUID(uuidString: "00000000-0000-4000-8000-000000000001")!
private let dashboardKey = "as_live_dashboard_fixture"
private let exactTokens = "922337203685477580812345"
private let dashboardModel = StudioModel(id: "claude-fixture", displayName: "Claude fixture", ownedBy: "claude", nativeProtocol: "messages")
private func dashboardIdentity(_ owner: UUID = dashboardOwner) -> StudioIdentity {
    StudioIdentity(user: StudioUser(id: owner, displayName: "Synthetic employee", role: "member", active: true, version: 1), orgID: dashboardOrg, apiVersion: "studio/v1")
}

private actor DashboardTransport: StudioHTTPTransport {
    var requests: [URLRequest] = []
    var failPath: String?, failStatus = 503, foreign = false, wrongSource = false
    func fail(_ path: String?, status: Int = 503) { failPath = path; failStatus = status }
    func makeForeign() { foreign = true }
    func corruptSource() { wrongSource = true }
    func send(_ request: URLRequest, origin: StudioOrigin) async throws -> StudioHTTPResponse {
        requests.append(request)
        let path = request.url!.path
        if path == failPath { return StudioHTTPResponse(status: failStatus, body: Data(#"{"error":{"code":"fixture_error"}}"#.utf8)) }
        let q = Dictionary(uniqueKeysWithValues: URLComponents(url: request.url!, resolvingAgainstBaseURL: false)!.queryItems!.map { ($0.name, $0.value!) })
        let totals: [String: Any] = ["total_tokens": exactTokens, "input_tokens": "922337203685477580800000", "output_tokens": "12345", "cache_read_tokens": "42", "cache_write_tokens": "10", "reasoning_tokens": "5"]
        let unknown = Dictionary(uniqueKeysWithValues: totals.keys.map { ($0, NSNull()) })
        let summary: [String: Any] = ["requests": "3", "confirmed_requests": "1", "unresolved_requests": "2", "disputed_requests": "1", "charged_tokens": exactTokens, "confirmed": totals]
        let owner = (foreign ? UUID() : dashboardOwner).uuidString.lowercased()
        var body: [String: Any]
        if path.hasSuffix("/policy") {
            body = ["policy_allowed": true, "admission_required": true, "user_id": owner, "key_id": dashboardOrg.uuidString,
                    "observed_at": "2026-09-28T00:00:00Z", "model_id": q["model"]!,
                    "policies": [["id": dashboardOrg.uuidString, "scope": "user"]],
                    "windows": [["id": dashboardOrg.uuidString, "policy_id": dashboardOrg.uuidString, "model_id": NSNull(), "period": "day", "timezone": "Asia/Ho_Chi_Minh", "tokens": 10000, "starts_at": "2026-09-27T17:00:00Z", "ends_at": "2026-09-28T17:00:00Z", "confirmed_tokens": "100", "reserved_tokens": "500", "remaining_tokens": "9400"]]]
        } else {
            body = ["source": wrongSource ? "local" : "studio_ledger", "timezone": q["timezone"] ?? "UTC", "observed_at": q["to"]!, "from": q["from"]!, "to": q["to"]!]
            if path.hasSuffix("/overview") {
                body["summary"] = summary
                body["models"] = [["id": dashboardModel.id, "label": dashboardModel.displayName, "requests": "3", "unresolved_requests": "2", "charged_tokens": exactTokens, "confirmed": totals]]
            } else {
                body["limit"] = 20; body["offset"] = 0
                body["requests"] = [
                    ["id": dashboardOrg.uuidString, "user_id": owner, "key_id": dashboardOrg.uuidString, "model_id": dashboardModel.id, "provider": "claude", "accounting_status": "confirmed", "created_at": q["from"]!, "charged_tokens": exactTokens, "confirmed": totals],
                    ["id": dashboardOwner.uuidString, "user_id": owner, "key_id": dashboardOrg.uuidString, "model_id": dashboardModel.id, "provider": "claude", "accounting_status": "unresolved", "created_at": q["from"]!, "charged_tokens": "0", "confirmed": unknown]]
            }
        }
        return StudioHTTPResponse(status: 200, body: try JSONSerialization.data(withJSONObject: body))
    }
}
private func fetchDashboard(_ transport: DashboardTransport = DashboardTransport()) async throws -> StudioDashboardSnapshot {
    try await StudioClient(transport: transport).dashboard(origin: StudioOrigin("https://studio.example"), key: dashboardKey, identity: dashboardIdentity(), model: dashboardModel, now: Date(timeIntervalSince1970: 1790575200), timezone: TimeZone(identifier: "Asia/Ho_Chi_Minh")!)
}

final class StudioDashboardClientTests: XCTestCase, @unchecked Sendable {
    func testExactDecimalAndUnknownAreNeverConvertedToFloatingPointOrZero() throws {
        XCTAssertEqual(try StudioCount(exactTokens).formatted, "922.337.203.685.477.580.812.345")
        XCTAssertEqual(try StudioCount("000").formatted, "0")
        for bad in ["", "-1", "1.5", "1e3", " 1", String(repeating: "1", count: 81)] { XCTAssertThrowsError(try StudioCount(bad)) }
        XCTAssertThrowsError(try JSONDecoder().decode(StudioCount.self, from: Data("123".utf8)))
    }
    func testCalendarRangesUseTimezoneAndDSTNotFixedDurations() throws {
        let formatter = ISO8601DateFormatter()
        let range = try StudioReportingRange(now: formatter.date(from: "2026-03-09T03:30:00Z")!, timezone: TimeZone(identifier: "America/New_York")!)
        XCTAssertEqual(formatter.string(from: range.today), "2026-03-08T05:00:00Z")
        XCTAssertEqual(formatter.string(from: range.month), "2026-03-01T05:00:00Z")
        XCTAssertEqual(range.until.timeIntervalSince(range.today), 22.5 * 3600)
        let midnight = try StudioReportingRange(now: formatter.date(from: "2026-10-01T00:00:00Z")!, timezone: TimeZone(identifier: "UTC")!)
        XCTAssertGreaterThan(midnight.until, midnight.today)
        XCTAssertEqual(midnight.today, midnight.month)
    }
    func testOwnRoutesRangesAndExactServerProjection() async throws {
        let transport = DashboardTransport(), result = try await fetchDashboard(transport)
        XCTAssertEqual(result.month.summary.confirmed.total_tokens?.value, exactTokens)
        XCTAssertEqual(result.recent.requests[1].confirmed.total_tokens, nil)
        XCTAssertEqual(result.recent.requests[1].charged_tokens.value, "0")
        XCTAssertEqual(result.month.summary.unresolved_requests.value, "2")
        XCTAssertEqual(result.month.summary.disputed_requests.value, "1")
        XCTAssertEqual(result.quota?.windows[0].reserved_tokens.value, "500")
        let requests = await transport.requests
        XCTAssertEqual(requests.map { $0.url!.path }, ["/studio/v1/me/overview", "/studio/v1/me/overview", "/studio/v1/me/usage", "/studio/v1/me/policy"])
        for request in requests {
            XCTAssertEqual(request.httpMethod, "GET"); XCTAssertNil(request.httpBody)
            XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer " + dashboardKey)
            let names = Set(URLComponents(url: request.url!, resolvingAgainstBaseURL: false)!.queryItems!.map(\.name))
            XCTAssertTrue(names.isDisjoint(with: ["user_id", "key_id", "account_id"]))
        }
    }
    func testQuotaFailureRemainsUnknownWithoutDiscardingVerifiedUsage() async throws {
        let transport = DashboardTransport(); await transport.fail("/studio/v1/me/policy")
        let result = try await fetchDashboard(transport)
        XCTAssertNil(result.quota); XCTAssertEqual(result.quotaError, .serverUnavailable)
        XCTAssertEqual(result.month.summary.confirmed.total_tokens?.value, exactTokens)
        await transport.fail("/studio/v1/me/policy", status: 401)
        do { _ = try await fetchDashboard(transport); XCTFail() } catch { XCTAssertEqual(error as? StudioError, .invalidKey) }
    }
    func testForeignOwnerOrWrongSourceAndPartialReportAreRejected() async throws {
        let foreign = DashboardTransport(); await foreign.makeForeign()
        let badSource = DashboardTransport(); await badSource.corruptSource()
        for transport in [foreign, badSource] {
            do { _ = try await fetchDashboard(transport); XCTFail() } catch { XCTAssertEqual(error as? StudioError, .invalidResponse) }
        }
        let partial = DashboardTransport(); await partial.fail("/studio/v1/me/usage")
        do { _ = try await fetchDashboard(partial); XCTFail() } catch { XCTAssertEqual(error as? StudioError, .serverUnavailable) }
    }
}

@MainActor private final class DashboardKeys: StudioKeyStorage {
    var key: String? = dashboardKey
    func load(profileID: String) throws -> String? { key }
    func save(_ key: String, profileID: String) throws { self.key = key }
    func delete(profileID: String) throws { key = nil }
}
@MainActor private final class DashboardSettings: StudioSettingsStorage {
    var value: StudioProfile?
    func load() throws -> StudioProfile? { value }
    func save(_ profile: StudioProfile?) { value = profile }
}
private actor DashboardConnection: StudioConnecting {
    var failure: StudioError?
    var models = [dashboardModel]
    func fail(_ error: StudioError?) { failure = error }
    func setModels(_ values: [StudioModel]) { models = values }
    func connect(origin: StudioOrigin, key: String) async throws -> StudioConnectionSnapshot {
        if let failure { throw failure }
        return StudioConnectionSnapshot(identity: dashboardIdentity(), capabilities: StudioCapabilities(apiVersion: "studio/v1", protocols: [], auth: ["bearer"]), models: .available(models))
    }
}
private actor SuspendedDashboard: StudioReporting {
    var waiter: CheckedContinuation<StudioDashboardSnapshot, any Error>?
    let value: StudioDashboardSnapshot
    init(_ value: StudioDashboardSnapshot) { self.value = value }
    func waiting() -> Bool { waiter != nil }
    func finish() { waiter?.resume(returning: value); waiter = nil }
    func dashboard(origin: StudioOrigin, key: String, identity: StudioIdentity, model: StudioModel?, now: Date, timezone: TimeZone) async throws -> StudioDashboardSnapshot {
        try await withCheckedThrowingContinuation { waiter = $0 }
    }
}

@MainActor final class StudioDashboardCacheTests: XCTestCase {
    func testCacheDeletionFailureStillRemovesEmployeeKeyAndBlocksOfflineRestore() async throws {
        @MainActor final class FailingCache: StudioDashboardCaching {
            var value: StudioDashboardSnapshot?
            var deletionFails = false
            func load(profile: StudioProfile) throws -> StudioDashboardSnapshot? { value }
            func save(_ snapshot: StudioDashboardSnapshot, profile: StudioProfile) throws { value = snapshot }
            func delete(profile: StudioProfile) throws { if deletionFails { throw StudioError.storage }; value = nil }
        }
        let cache = FailingCache(), keys = DashboardKeys(), settings = DashboardSettings()
        let store = StudioConnectionStore(client: DashboardConnection(), keys: keys, settings: settings, reporting: StudioClient(transport: DashboardTransport()), cache: cache)
        await store.connect(origin: "https://studio.example", key: dashboardKey)
        cache.deletionFails = true; store.disconnect()
        XCTAssertNil(store.dashboard); XCTAssertNil(keys.key); XCTAssertEqual(store.error, .storage)
        XCTAssertNotNil(settings.value)
        let restored = StudioConnectionStore(client: DashboardConnection(), keys: keys, settings: settings, cache: cache)
        XCTAssertNil(restored.dashboard)
        cache.deletionFails = false; restored.disconnect()
        XCTAssertNil(settings.value); XCTAssertNil(cache.value)
    }
    func testCorruptAndSymlinkCacheNeverLoadsOrOverwritesOtherFile() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let cache = StudioDashboardCache(directory: directory), value = try await fetchDashboard()
        let origin = try StudioOrigin("https://studio.example")
        let profile = try StudioProfile(origin: origin, id: origin.profileID(orgID: dashboardOrg, ownerID: dashboardOwner))
        try cache.save(value, profile: profile)
        let path = directory.appendingPathComponent(profile.id + ".json")
        try Data("invalid-cache".utf8).write(to: path)
        XCTAssertThrowsError(try cache.load(profile: profile))
        try FileManager.default.removeItem(at: path)
        let target = directory.appendingPathComponent("unrelated.txt")
        try Data("untouched".utf8).write(to: target)
        try FileManager.default.createSymbolicLink(at: path, withDestinationURL: target)
        XCTAssertThrowsError(try cache.load(profile: profile))
        XCTAssertThrowsError(try cache.save(value, profile: profile))
        XCTAssertThrowsError(try cache.delete(profile: profile))
        XCTAssertEqual(try String(contentsOf: target, encoding: .utf8), "untouched")
    }
    func testReportRevocationAndModelChangeClearOldQuotaBeforeLoading() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let cache = StudioDashboardCache(directory: directory), connection = DashboardConnection(), transport = DashboardTransport()
        let second = StudioModel(id: "codex-fixture", displayName: "Codex fixture", ownedBy: "codex", nativeProtocol: "responses")
        await connection.setModels([dashboardModel, second])
        let store = StudioConnectionStore(client: connection, keys: DashboardKeys(), settings: DashboardSettings(), reporting: StudioClient(transport: transport), cache: cache)
        await store.connect(origin: "https://studio.example", key: dashboardKey)
        let profile = try XCTUnwrap(store.profile)
        XCTAssertEqual(store.dashboard?.quotaModel?.id, dashboardModel.id)
        await transport.fail("/studio/v1/me/usage")
        // A model removed by fresh discovery must not label old quota as the replacement.
        await connection.setModels([second]); await store.refresh()
        XCTAssertNil(store.dashboard); XCTAssertNil(try cache.load(profile: profile))
        await transport.fail(nil); await store.refresh()
        XCTAssertEqual(store.dashboard?.quotaModel?.id, second.id)
        XCTAssertEqual(store.dashboard?.quota?.model_id, second.id)
        await connection.setModels([dashboardModel, second]); await store.refresh()
        await transport.fail("/studio/v1/me/usage")
        await store.selectQuotaModel(dashboardModel.id)
        XCTAssertNil(store.dashboard); XCTAssertNil(try cache.load(profile: profile))
        await transport.fail("/studio/v1/me/usage", status: 401); await store.refresh()
        XCTAssertNil(store.dashboard); XCTAssertNil(store.snapshot); XCTAssertNil(try cache.load(profile: profile))
        XCTAssertEqual(store.state, .failed); XCTAssertEqual(store.error, .invalidKey)
    }
    func testDiskCacheIsPrivateScopedValidatedAndContainsNoCredential() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let cache = StudioDashboardCache(directory: directory), value = try await fetchDashboard()
        let origin = try StudioOrigin("https://studio.example")
        let profile = try StudioProfile(origin: origin, id: origin.profileID(orgID: dashboardOrg, ownerID: dashboardOwner))
        try cache.save(value, profile: profile)
        XCTAssertEqual(try cache.load(profile: profile), value)
        let path = directory.appendingPathComponent(profile.id + ".json")
        let raw = try String(contentsOf: path, encoding: .utf8)
        XCTAssertFalse(raw.contains(dashboardKey)); XCTAssertFalse(raw.contains("Authorization"))
        XCTAssertEqual(try FileManager.default.attributesOfItem(atPath: directory.path)[.posixPermissions] as? Int, 0o700)
        XCTAssertEqual(try FileManager.default.attributesOfItem(atPath: path.path)[.posixPermissions] as? Int, 0o600)
        let otherOrigin = try StudioOrigin("https://other.example")
        let other = try StudioProfile(origin: otherOrigin, id: otherOrigin.profileID(orgID: dashboardOrg, ownerID: dashboardOwner))
        XCTAssertNil(try cache.load(profile: other))
        try Data(raw.utf8).write(to: directory.appendingPathComponent(other.id + ".json"))
        XCTAssertThrowsError(try cache.load(profile: other))
        try cache.delete(profile: profile)
        XCTAssertNil(try cache.load(profile: profile))
        XCTAssertTrue(FileManager.default.fileExists(atPath: directory.appendingPathComponent(other.id + ".json").path))
    }
    func testReloadShowsStaleSnapshotOfflineButRevocationAndDisconnectRemoveIt() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let cache = StudioDashboardCache(directory: directory), keys = DashboardKeys(), settings = DashboardSettings(), connection = DashboardConnection()
        let reporting = StudioClient(transport: DashboardTransport())
        let store = StudioConnectionStore(client: connection, keys: keys, settings: settings, reporting: reporting, cache: cache)
        await store.connect(origin: "https://studio.example", key: dashboardKey)
        XCTAssertEqual(store.dashboardState, .current)
        let profile = try XCTUnwrap(store.profile)
        let restored = StudioConnectionStore(client: connection, keys: keys, settings: settings, reporting: reporting, cache: cache)
        XCTAssertEqual(restored.dashboardState, .stale); XCTAssertNil(restored.snapshot)
        await connection.fail(.offline); await restored.refresh()
        XCTAssertNotNil(restored.dashboard); XCTAssertEqual(restored.dashboardState, .stale)
        await connection.fail(.invalidKey); await restored.refresh()
        XCTAssertNil(restored.dashboard); XCTAssertNil(try cache.load(profile: profile))
        await connection.fail(.offline); await restored.refresh()
        XCTAssertNil(restored.dashboard); XCTAssertEqual(restored.dashboardState, .failed)
        await connection.fail(nil); await restored.refresh()
        XCTAssertNotNil(restored.dashboard)
        restored.disconnect()
        XCTAssertNil(restored.dashboard); XCTAssertNil(try cache.load(profile: profile)); XCTAssertNil(keys.key); XCTAssertNil(settings.value)
    }
    func testDisconnectDuringReportingCannotRecreateDiskCache() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let cache = StudioDashboardCache(directory: directory), reporter = SuspendedDashboard(try await fetchDashboard()), settings = DashboardSettings()
        let store = StudioConnectionStore(client: DashboardConnection(), keys: DashboardKeys(), settings: settings, reporting: reporter, cache: cache)
        let connect = Task { await store.connect(origin: "https://studio.example", key: dashboardKey) }
        for _ in 0..<1000 { if await reporter.waiting() { break }; await Task.yield() }
        let waiting = await reporter.waiting(); XCTAssertTrue(waiting)
        let profile = try XCTUnwrap(store.profile)
        store.disconnect(); await reporter.finish(); await connect.value
        XCTAssertNil(store.dashboard); XCTAssertNil(try cache.load(profile: profile)); XCTAssertNil(settings.value)
    }
}
