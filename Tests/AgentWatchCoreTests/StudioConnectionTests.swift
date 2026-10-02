import XCTest
import Security
@testable import AgentWatchCore

private let studioOwner = UUID(uuidString: "00000000-0000-4000-8000-000000000002")!
private let studioOrg = UUID(uuidString: "00000000-0000-4000-8000-000000000001")!
private let fixtureKey = "as_live_synthetic_fixture_key"
private let capabilityJSON = #"{"api_version":"studio/v1","protocols":[],"auth":["bearer","x-api-key"]}"#
private let identityJSON = #"{"api_version":"studio/v1","org_id":"00000000-0000-4000-8000-000000000001","user":{"id":"00000000-0000-4000-8000-000000000002","display_name":"Fixture employee","role":"member","active":true,"version":1}}"#
private let modelsJSON = #"{"object":"list","admission_required":true,"data":[{"id":"claude-test","display_name":"Claude fixture","owned_by":"claude","protocol":"messages"}]}"#
private func response(_ text: String, _ status: Int = 200, type: String = "application/json") -> StudioHTTPResponse {
    StudioHTTPResponse(status: status, contentType: type, body: Data(text.utf8))
}
private func snapshot(owner: UUID = studioOwner) -> StudioConnectionSnapshot {
    StudioConnectionSnapshot(identity: StudioIdentity(user: StudioUser(id: owner, displayName: "Fixture employee", role: "member", active: true, version: 1), orgID: studioOrg, apiVersion: "studio/v1"),
                             capabilities: StudioCapabilities(apiVersion: "studio/v1", protocols: [], auth: ["bearer"]), models: .available([]))
}

private actor FixtureStudioTransport: StudioHTTPTransport {
    var replies: [StudioHTTPResponse]
    var requests: [URLRequest] = []
    init(_ replies: [StudioHTTPResponse]) { self.replies = replies }
    func send(_ request: URLRequest, origin: StudioOrigin) async throws -> StudioHTTPResponse {
        requests.append(request)
        guard !replies.isEmpty else { throw StudioError.offline }
        return replies.removeFirst()
    }
}
private actor FixtureStudioClient: StudioConnecting {
    var result: Result<StudioConnectionSnapshot, StudioError> = .success(snapshot())
    var continuation: CheckedContinuation<StudioConnectionSnapshot, any Error>?
    var shouldSuspend = false
    func set(_ result: Result<StudioConnectionSnapshot, StudioError>) { self.result = result }
    func suspend() { shouldSuspend = true }
    func waiting() -> Bool { continuation != nil }
    func finish() { continuation?.resume(with: result.mapError { $0 as any Error }); continuation = nil }
    func connect(origin: StudioOrigin, key: String) async throws -> StudioConnectionSnapshot {
        if shouldSuspend { return try await withCheckedThrowingContinuation { continuation = $0 } }
        return try result.get()
    }
}
@MainActor private final class FixtureStudioKeys: StudioKeyStorage {
    var values: [String: String] = [:]
    var failSave = false, failDelete = false
    func load(profileID: String) throws -> String? { values[profileID] }
    func save(_ key: String, profileID: String) throws { if failSave { throw StudioError.storage }; values[profileID] = key }
    func delete(profileID: String) throws { if failDelete { throw StudioError.storage }; values[profileID] = nil }
}
@MainActor private final class FixtureStudioSettings: StudioSettingsStorage {
    var profile: StudioProfile?
    func load() throws -> StudioProfile? { profile }
    func save(_ profile: StudioProfile?) { self.profile = profile }
}

@MainActor private final class InteractionTrackingKeys: StudioKeyStorage {
    var interactions: [Bool] = []
    func load(profileID: String) throws -> String? { try load(profileID: profileID, allowInteraction: true) }
    func load(profileID: String, allowInteraction: Bool) throws -> String? {
        interactions.append(allowInteraction)
        if !allowInteraction { throw StudioError.keychainApprovalRequired }
        return fixtureKey
    }
    func save(_ key: String, profileID: String) {}
    func delete(profileID: String) {}
}

final class StudioClientTests: XCTestCase, @unchecked Sendable {
    @MainActor func testNoninteractiveKeychainReadRestoresExistingInteractionSetting() throws {
        var original = DarwinBoolean(false)
        XCTAssertEqual(SecKeychainGetUserInteractionAllowed(&original), errSecSuccess)
        defer { SecKeychainSetUserInteractionAllowed(original.boolValue) }
        let storage = StudioKeychainStorage(testService: "studio-noninteractive-test-" + UUID().uuidString)
        for allowed in [false, true] {
            XCTAssertEqual(SecKeychainSetUserInteractionAllowed(allowed), errSecSuccess)
            XCTAssertNil(try storage.load(profileID: String(repeating: "a", count: 64), allowInteraction: false))
            var after = DarwinBoolean(false)
            XCTAssertEqual(SecKeychainGetUserInteractionAllowed(&after), errSecSuccess)
            XCTAssertEqual(after.boolValue, allowed)
        }
    }

    @MainActor func testStartupAndAutomaticRefreshNeverPromptForKeychain() async throws {
        let keys = InteractionTrackingKeys(), settings = FixtureStudioSettings()
        let origin = try StudioOrigin("https://studio.test")
        settings.profile = try StudioProfile(origin: origin, id: origin.profileID(orgID: studioOrg, ownerID: studioOwner))
        let store = StudioConnectionStore(client: FixtureStudioClient(), keys: keys, settings: settings)
        XCTAssertEqual(keys.interactions, [false])
        await store.refresh(allowInteraction: false)
        XCTAssertEqual(keys.interactions, [false, false])
        XCTAssertEqual(store.error, .keychainApprovalRequired)
        await store.refresh()
        XCTAssertEqual(keys.interactions, [false, false, true])
        XCTAssertEqual(store.state, .connected)
    }

    @MainActor func testReconnectClearsOnlyTheInjectedPreferencesCredentialBlock() async throws {
        let suite = "studio-connect-scope-" + UUID().uuidString
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        defaults.set("previous-block", forKey: "studio.blockedProfile")
        defaults.set([try StudioOrigin("https://studio.test").profileID(orgID: studioOrg, ownerID: studioOwner), "other-slot"], forKey: "studio.blockedProfiles.v2")
        let store = StudioConnectionStore(client: FixtureStudioClient(), keys: FixtureStudioKeys(), settings: StudioPreferences(defaults: defaults))
        await store.connect(origin: "https://studio.test", key: fixtureKey)
        XCTAssertEqual(store.state, .connected)
        XCTAssertEqual(defaults.string(forKey: "studio.blockedProfile"), "previous-block", "Connecting one slot cannot unblock a different credential")
        XCTAssertEqual(defaults.stringArray(forKey: "studio.blockedProfiles.v2"), ["other-slot"])
    }

    func testRealURLSessionDoesNotForwardEmployeeKeyThroughRedirect() async throws {
        // Two real loopback HTTP listeners. Only a synthetic key is sent. A hard
        // process alarm bounds fixture startup even if the child cannot bind.
        let script = #"""
import http.server, threading, json, signal
signal.alarm(20)
observed = {"target_calls": 0, "capability_has_auth": False, "me_has_expected_auth": False}
class Target(http.server.BaseHTTPRequestHandler):
    def log_message(self, *args): pass
    def do_GET(self):
        observed["target_calls"] += 1
        self.send_response(200); self.send_header("Content-Length", "0"); self.end_headers()
target = http.server.ThreadingHTTPServer(("127.0.0.1", 0), Target)
class Source(http.server.BaseHTTPRequestHandler):
    def log_message(self, *args): pass
    def do_GET(self):
        if self.path == "/studio/v1/me":
            observed["me_has_expected_auth"] = self.headers.get("Authorization") == "Bearer as_live_synthetic_fixture_key"
            self.send_response(302)
            self.send_header("Location", "http://127.0.0.1:%d/capture" % target.server_port)
            self.send_header("Content-Length", "0"); self.end_headers(); return
        if self.path == "/studio/v1/capabilities":
            observed["capability_has_auth"] = self.headers.get("Authorization") is not None
            value = {"api_version": "studio/v1", "auth": ["bearer"], "protocols": []}
        else: value = observed
        body = json.dumps(value).encode()
        self.send_response(200); self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(body))); self.end_headers(); self.wfile.write(body)
source = http.server.ThreadingHTTPServer(("127.0.0.1", 0), Source)
threading.Thread(target=target.serve_forever, daemon=True).start()
print(source.server_port, flush=True)
source.serve_forever()
"""#
        let process = Process(), pipe = Pipe()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/python3")
        process.arguments = ["-u", "-c", script]; process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice
        try process.run()
        defer { if process.isRunning { process.terminate() }; process.waitUntilExit() }
        var line = Data()
        while line.count < 32 {
            let byte = pipe.fileHandleForReading.readData(ofLength: 1)
            if byte.isEmpty || byte == Data([10]) { break }; line.append(byte)
        }
        let port = try XCTUnwrap(Int(String(decoding: line, as: UTF8.self)))
        let origin = try StudioOrigin("http://127.0.0.1:\(port)")
        do { _ = try await StudioClient().connect(origin: origin, key: fixtureKey); XCTFail("Redirect accepted") }
        catch { XCTAssertEqual(error as? StudioError, .redirectDenied) }
        let observed = try await StudioURLSessionTransport().send(URLRequest(url: origin.url(path: "observations")), origin: origin)
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: observed.body) as? [String: Any])
        XCTAssertEqual(json["target_calls"] as? Int, 0)
        XCTAssertEqual(json["capability_has_auth"] as? Bool, false)
        XCTAssertEqual(json["me_has_expected_auth"] as? Bool, true)
    }
    func testOriginCanonicalizationAndUnsafeInputs() throws {
        XCTAssertEqual(try StudioOrigin(" HTTPS://Studio.example:443/ ").value, "https://studio.example")
        XCTAssertEqual(try StudioOrigin("http://[::1]:17822/").value, "http://[::1]:17822")
        for value in ["http://studio.example", "http://localhost", "http://127.1", "https://u:p@studio.example", "https://studio.example/api", "https://studio.example?key=secret", "https://studio.example#key", "https://studio.example:0", "https://studio.example:65536", "https://studio.example\\evil", "https://studio.%65xample", "https://stu\ndio.example"] {
            XCTAssertThrowsError(try StudioOrigin(value), value)
        }
        let origin = try StudioOrigin("https://studio.example")
        XCTAssertTrue(origin.contains(URL(string: "https://studio.example:443/studio/v1/me")!))
        XCTAssertFalse(origin.contains(URL(string: "https://other.example/studio/v1/me")!))
        XCTAssertFalse(origin.contains(URL(string: "http://studio.example/studio/v1/me")!))
        XCTAssertFalse(origin.contains(URL(string: "https://studio.example:444/studio/v1/me")!))
        XCTAssertNotEqual(origin.profileID(orgID: studioOrg, ownerID: studioOwner), try StudioOrigin("https://other.example").profileID(orgID: studioOrg, ownerID: studioOwner))
        XCTAssertNotEqual(origin.profileID(orgID: studioOrg, ownerID: studioOwner), origin.profileID(orgID: studioOrg, ownerID: UUID()))
        XCTAssertNotEqual(origin.profileID(orgID: studioOrg, ownerID: studioOwner), origin.profileID(orgID: UUID(), ownerID: studioOwner))
    }
    func testConnectionVerifiesPublicVersionBeforeSendingKey() async throws {
        let fixture = FixtureStudioTransport([response(capabilityJSON), response(identityJSON), response(modelsJSON)])
        let result = try await StudioClient(transport: fixture).connect(origin: StudioOrigin("https://studio.example"), key: fixtureKey)
        XCTAssertEqual(result.identity.user.id, studioOwner)
        guard case .available(let models) = result.models else { return XCTFail("Expected verified models") }
        XCTAssertEqual(models.map(\.id), ["claude-test"])
        let requests = await fixture.requests
        XCTAssertEqual(requests.map { $0.url!.path }, ["/studio/v1/capabilities", "/studio/v1/me", "/v1/models"])
        XCTAssertNil(requests[0].value(forHTTPHeaderField: "Authorization"))
        XCTAssertEqual(requests[1].value(forHTTPHeaderField: "Authorization"), "Bearer " + fixtureKey)
        XCTAssertEqual(requests[2].value(forHTTPHeaderField: "Authorization"), "Bearer " + fixtureKey)
        XCTAssertTrue(requests.allSatisfy { $0.httpBody == nil && $0.httpMethod == "GET" && $0.url!.host == "studio.example" })
    }
    func testIncompatibleVersionNeverReceivesCredential() async throws {
        let fixture = FixtureStudioTransport([response(capabilityJSON.replacingOccurrences(of: "studio/v1", with: "studio/v2"))])
        do { _ = try await StudioClient(transport: fixture).connect(origin: StudioOrigin("https://studio.example"), key: fixtureKey); XCTFail() }
        catch { XCTAssertEqual(error as? StudioError, .incompatibleVersion) }
        let requests = await fixture.requests
        XCTAssertEqual(requests.count, 1); XCTAssertNil(requests.first?.value(forHTTPHeaderField: "Authorization"))
    }
    func testInvalidKeyNeverStartsNetwork() async throws {
        let fixture = FixtureStudioTransport([])
        for key in ["", "key\r\nAuthorization: other", "has space", String(repeating: "x", count: 4097)] {
            do { _ = try await StudioClient(transport: fixture).connect(origin: StudioOrigin("https://studio.example"), key: key); XCTFail() }
            catch { XCTAssertEqual(error as? StudioError, .invalidKey) }
        }
        let requests = await fixture.requests; XCTAssertTrue(requests.isEmpty)
    }
    func testUnavailableOrForbiddenModelsRetainVerifiedIdentityButRevocationDoesNot() async throws {
        for (status, expected) in [(403, StudioError.permissionDenied), (503, .serverUnavailable), (429, .quotaExceeded)] {
            let fixture = FixtureStudioTransport([response(capabilityJSON), response(identityJSON), response(#"{"error":{"code":"token_quota_exhausted","message":"must never be displayed"}}"#, status)])
            let result = try await StudioClient(transport: fixture).connect(origin: StudioOrigin("https://studio.example"), key: fixtureKey)
            XCTAssertEqual(result.models, .unavailable(expected)); XCTAssertEqual(result.identity.user.id, studioOwner)
        }
        let revoked = FixtureStudioTransport([response(capabilityJSON), response(identityJSON), response("{}", 401)])
        do { _ = try await StudioClient(transport: revoked).connect(origin: StudioOrigin("https://studio.example"), key: fixtureKey); XCTFail() }
        catch { XCTAssertEqual(error as? StudioError, .invalidKey) }
    }
    func testMalformedResponsesAndRedirectsFailClosed() async throws {
        for (reply, expected) in [(response("<html>ok</html>", type: "text/html"), StudioError.invalidResponse), (response("{}"), .invalidResponse), (response("", 302), .redirectDenied), (response(String(repeating: "x", count: StudioClient.maxResponseBytes + 1)), .invalidResponse)] {
            let fixture = FixtureStudioTransport([reply])
            do { _ = try await StudioClient(transport: fixture).connect(origin: StudioOrigin("https://studio.example"), key: fixtureKey); XCTFail() }
            catch { XCTAssertEqual(error as? StudioError, expected) }
        }
        for invalid in [identityJSON.replacingOccurrences(of: "\"active\":true", with: "\"active\":false"), identityJSON.replacingOccurrences(of: "\"member\"", with: "\"unknown\"")] {
            let fixture = FixtureStudioTransport([response(capabilityJSON), response(invalid)])
            do { _ = try await StudioClient(transport: fixture).connect(origin: StudioOrigin("https://studio.example"), key: fixtureKey); XCTFail() }
            catch { XCTAssertEqual(error as? StudioError, .invalidResponse) }
        }
    }
    func testDuplicateAndWrongProtocolModelsAreRejected() async throws {
        let row = #"{"id":"a","display_name":"A","owned_by":"claude","protocol":"messages"}"#
        for bad in [#"{"object":"list","admission_required":true,"data":["# + row + "," + row + "]}", modelsJSON.replacingOccurrences(of: "messages", with: "responses"), modelsJSON.replacingOccurrences(of: "\"admission_required\":true", with: "\"admission_required\":false")] {
            let fixture = FixtureStudioTransport([response(capabilityJSON), response(identityJSON), response(bad)])
            do { _ = try await StudioClient(transport: fixture).connect(origin: StudioOrigin("https://studio.example"), key: fixtureKey); XCTFail() }
            catch { XCTAssertEqual(error as? StudioError, .invalidResponse) }
        }
    }
}

@MainActor final class StudioConnectionStoreTests: XCTestCase {
    func testTwoCredentialsKeepSecretsSeparateAndDisconnectOnlySelectedSlot() async throws {
        let suite = "studio-slots-" + UUID().uuidString, defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let settings = StudioPreferences(defaults: defaults), keys = FixtureStudioKeys(), client = FixtureStudioClient()
        let store = StudioConnectionStore(client: client, keys: keys, settings: settings)
        func result(_ mode: StudioCredentialMode, _ id: UUID) -> StudioConnectionSnapshot {
            var identity = snapshot().identity; identity.keyID = id; identity.credentialMode = mode
            return StudioConnectionSnapshot(identity: identity, capabilities: snapshot().capabilities, models: .available([]))
        }
        let direct = result(.direct, UUID()), managed = result(.managed, UUID())
        await client.set(.success(direct)); await store.connect(origin: "https://studio.test", key: "direct_fixture")
        let directProfile = try XCTUnwrap(store.profile)
        await client.set(.success(managed)); await store.connect(origin: "https://studio.test", key: "managed_fixture")
        let managedProfile = try XCTUnwrap(store.profile)
        XCTAssertEqual(store.state, .connected); XCTAssertEqual(store.availableProfiles.count, 2)
        XCTAssertNotEqual(directProfile.id, managedProfile.id); XCTAssertEqual(directProfile.connectionID, managedProfile.connectionID)
        XCTAssertEqual(keys.values[directProfile.id], "direct_fixture")
        XCTAssertEqual(keys.values[managedProfile.id], "managed_fixture")
        // Selecting a different UI slot must not redirect the existing direct helper.
        XCTAssertEqual(StudioCredentialCommand.savedKey(profileID: directProfile.id, defaults: defaults, settings: settings, keys: keys), "direct_fixture")
        XCTAssertNil(StudioCredentialCommand.savedKey(profileID: managedProfile.id, defaults: defaults, settings: settings, keys: keys))
        defaults.set([directProfile.id], forKey: "studio.blockedProfiles.v2")
        XCTAssertNil(StudioCredentialCommand.savedKey(profileID: directProfile.id, defaults: defaults, settings: settings, keys: keys))
        settings.clearCredentialBlock(profileID: managedProfile.id)
        XCTAssertEqual(defaults.stringArray(forKey: "studio.blockedProfiles.v2"), [directProfile.id])
        store.disconnect()
        XCTAssertEqual(store.availableProfiles, [directProfile]); XCTAssertNil(keys.values[managedProfile.id])
        XCTAssertEqual(keys.values[directProfile.id], "direct_fixture")
        await client.set(.success(direct)); await store.selectProfile(directProfile.id)
        XCTAssertEqual(store.state, .connected); XCTAssertEqual(store.profile, directProfile)
        await client.set(.success(managed)); await store.refresh()
        XCTAssertEqual(store.error, .identityChanged)
    }

    func testLegacyProfileMigrationPreservesExistingConfigIdentity() async throws {
        let suite = "studio-slot-migration-" + UUID().uuidString, defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let origin = try StudioOrigin("https://studio.test")
        let legacy = try StudioProfile(origin: origin, id: origin.profileID(orgID: studioOrg, ownerID: studioOwner))
        defaults.set(try JSONEncoder().encode(legacy), forKey: "studio.activeProfile.v1")
        let settings = StudioPreferences(defaults: defaults), keys = FixtureStudioKeys(), client = FixtureStudioClient()
        try keys.save(fixtureKey, profileID: legacy.id)
        var identity = snapshot().identity; identity.keyID = UUID(); identity.credentialMode = .direct
        await client.set(.success(StudioConnectionSnapshot(identity: identity, capabilities: snapshot().capabilities, models: .available([]))))
        let store = StudioConnectionStore(client: client, keys: keys, settings: settings)
        await store.connect(origin: origin.value, key: fixtureKey)
        XCTAssertEqual(store.profile, legacy); XCTAssertEqual(try settings.profiles(), [legacy])
        XCTAssertNil(defaults.data(forKey: "studio.activeProfile.v1"))
        XCTAssertEqual(try StudioPreferences(defaults: defaults).load(), legacy)
    }

    func testCorruptCollectionDoesNotOverwriteOrResurrectLegacyProfile() throws {
        let suite = "studio-slot-corrupt-" + UUID().uuidString, defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let profile = try StudioProfile(origin: StudioOrigin("https://studio.test"), id: String(repeating: "a", count: 64))
        defaults.set(try JSONEncoder().encode(profile), forKey: "studio.activeProfile.v1")
        let corrupt = Data("invalid".utf8); defaults.set(corrupt, forKey: "studio.profiles.v2")
        let settings = StudioPreferences(defaults: defaults)
        XCTAssertThrowsError(try settings.load()); XCTAssertThrowsError(try settings.saveChecked(profile))
        XCTAssertEqual(defaults.data(forKey: "studio.profiles.v2"), corrupt)
    }

    func testSaveRestoreRotationAndDisconnectUseOnlyScopedKeychain() async throws {
        let keys = FixtureStudioKeys(), settings = FixtureStudioSettings(), client = FixtureStudioClient()
        let store = StudioConnectionStore(client: client, keys: keys, settings: settings, cache: ConnectionTestCache())
        await store.connect(origin: "https://studio.example", key: fixtureKey)
        let id = try XCTUnwrap(store.profile?.id)
        XCTAssertEqual(keys.values[id], fixtureKey); XCTAssertEqual(store.state, .connected)
        let restored = StudioConnectionStore(client: client, keys: keys, settings: settings, cache: ConnectionTestCache())
        XCTAssertEqual(restored.state, .saved); XCTAssertNil(restored.snapshot)
        await restored.refresh(); XCTAssertEqual(restored.snapshot?.identity.user.id, studioOwner)
        await restored.connect(origin: "https://studio.example", key: "rotated_fixture_key")
        XCTAssertEqual(restored.profile?.id, id); XCTAssertEqual(keys.values.count, 1)
        XCTAssertEqual(keys.values[id], "rotated_fixture_key")
        restored.disconnect()
        XCTAssertTrue(keys.values.isEmpty); XCTAssertNil(settings.profile); XCTAssertNil(restored.snapshot); XCTAssertEqual(restored.state, .disconnected)
    }
    func testDisconnectWhileConnectingCannotResurrectCredential() async throws {
        let keys = FixtureStudioKeys(), settings = FixtureStudioSettings(), client = FixtureStudioClient()
        await client.suspend()
        let store = StudioConnectionStore(client: client, keys: keys, settings: settings, cache: ConnectionTestCache())
        let task = Task { await store.connect(origin: "https://studio.example", key: fixtureKey) }
        for _ in 0..<1000 { if await client.waiting() { break }; await Task.yield() }
        let waiting = await client.waiting(); XCTAssertTrue(waiting)
        store.disconnect(); await client.finish(); await task.value
        XCTAssertTrue(keys.values.isEmpty); XCTAssertNil(settings.profile); XCTAssertNil(store.snapshot); XCTAssertEqual(store.state, .disconnected)
    }
    func testOfflineCacheIsExplicitlyStaleAndRevocationClearsIt() async {
        let client = FixtureStudioClient()
        let store = StudioConnectionStore(client: client, keys: FixtureStudioKeys(), settings: FixtureStudioSettings(), cache: ConnectionTestCache())
        await store.connect(origin: "https://studio.example", key: fixtureKey)
        let previous = store.snapshot
        await client.set(.failure(.offline)); await store.refresh()
        XCTAssertEqual(store.snapshot, previous); XCTAssertEqual(store.state, .stale); XCTAssertEqual(store.error, .offline)
        await client.set(.failure(.invalidKey)); await store.refresh()
        XCTAssertNil(store.snapshot); XCTAssertEqual(store.state, .failed); XCTAssertEqual(store.error, .invalidKey)
    }
    func testDisconnectDuringRefreshDropsLateIdentityAndCancelledConnectDoesNotSave() async {
        let client = FixtureStudioClient(), keys = FixtureStudioKeys(), settings = FixtureStudioSettings()
        let store = StudioConnectionStore(client: client, keys: keys, settings: settings, cache: ConnectionTestCache())
        await store.connect(origin: "https://studio.example", key: fixtureKey)
        await client.suspend()
        let refresh = Task { await store.refresh() }
        for _ in 0..<1000 { if await client.waiting() { break }; await Task.yield() }
        let refreshing = await client.waiting(); XCTAssertTrue(refreshing)
        store.disconnect(); await client.finish(); await refresh.value
        XCTAssertNil(store.snapshot); XCTAssertNil(store.profile); XCTAssertTrue(keys.values.isEmpty)
        let connect = Task { await store.connect(origin: "https://studio.example", key: fixtureKey) }
        for _ in 0..<1000 { if await client.waiting() { break }; await Task.yield() }
        let connecting = await client.waiting(); XCTAssertTrue(connecting)
        connect.cancel(); await client.finish(); await connect.value
        XCTAssertNil(store.snapshot); XCTAssertNil(store.profile); XCTAssertTrue(keys.values.isEmpty)
        XCTAssertEqual(store.state, .disconnected)
    }
    func testIdentityAndOriginChangesNeverOverwriteExistingKeyOrExposeOldSnapshot() async throws {
        let client = FixtureStudioClient(), keys = FixtureStudioKeys(), settings = FixtureStudioSettings()
        let store = StudioConnectionStore(client: client, keys: keys, settings: settings, cache: ConnectionTestCache())
        await store.connect(origin: "https://studio.example", key: fixtureKey)
        let original = store.profile
        await store.connect(origin: "https://other.example", key: "other_key")
        XCTAssertEqual(store.error, .disconnectFirst); XCTAssertNil(store.snapshot); XCTAssertEqual(store.profile, original)
        await client.set(.success(snapshot(owner: UUID())))
        await store.refresh()
        XCTAssertEqual(store.error, .identityChanged); XCTAssertNil(store.snapshot)
        await store.connect(origin: "https://studio.example", key: "other_key")
        XCTAssertEqual(store.error, .disconnectFirst); XCTAssertNil(store.snapshot); XCTAssertEqual(store.profile, original)
        XCTAssertEqual(keys.values, [try XCTUnwrap(original?.id): fixtureKey])
        store.disconnect()
        await store.connect(origin: "https://other.example", key: "other_key")
        XCTAssertEqual(store.state, .connected); XCTAssertNotEqual(store.profile?.id, original?.id)
        XCTAssertEqual(keys.values.count, 1); XCTAssertNil(keys.values[try XCTUnwrap(original?.id)])
    }
    func testStorageFailuresDoNotClaimSuccessOrForgetDeleteRetry() async {
        let keys = FixtureStudioKeys(), settings = FixtureStudioSettings()
        let store = StudioConnectionStore(client: FixtureStudioClient(), keys: keys, settings: settings, cache: ConnectionTestCache())
        keys.failSave = true
        await store.connect(origin: "https://studio.example", key: fixtureKey)
        XCTAssertEqual(store.error, .storage); XCTAssertNil(store.snapshot); XCTAssertNil(settings.profile)
        keys.failSave = false
        await store.connect(origin: "https://studio.example", key: fixtureKey)
        keys.failDelete = true; store.disconnect()
        XCTAssertEqual(store.error, .storage); XCTAssertNil(store.snapshot); XCTAssertNotNil(store.profile); XCTAssertNotNil(settings.profile)
        keys.failDelete = false; store.disconnect()
        XCTAssertNil(settings.profile); XCTAssertTrue(keys.values.isEmpty)
    }
    func testPreferencesPersistOnlyValidatedOriginAndProfileID() throws {
        let name = "studio-fixture-" + UUID().uuidString
        let defaults = try XCTUnwrap(UserDefaults(suiteName: name))
        defer { defaults.removePersistentDomain(forName: name) }
        let preferences = StudioPreferences(defaults: defaults)
        let profile = try StudioProfile(origin: StudioOrigin("https://studio.example"), id: String(repeating: "a", count: 64))
        preferences.save(profile)
        XCTAssertEqual(try preferences.load(), profile)
        let data = try XCTUnwrap(defaults.data(forKey: "studio.profiles.v2"))
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        XCTAssertEqual(Set(json.keys), ["profiles", "selected"])
        let profiles = try XCTUnwrap(json["profiles"] as? [[String: String]])
        XCTAssertEqual(Set(profiles[0].keys), ["origin", "id"])
        defaults.set(Data(#"{"profiles":[{"origin":"http://evil.example","id":"secret"}]}"#.utf8), forKey: "studio.profiles.v2")
        XCTAssertThrowsError(try preferences.load())
    }
    func testRealKeychainRoundTripInUniqueFixtureNamespace() throws {
        let storage = StudioKeychainStorage(testService: "com.vtamm.agentwatch.studio.test." + UUID().uuidString)
        let first = String(repeating: "a", count: 64), second = String(repeating: "b", count: 64)
        defer { try? storage.delete(profileID: first); try? storage.delete(profileID: second) }
        XCTAssertNil(try storage.load(profileID: first))
        try storage.save(fixtureKey, profileID: first)
        try storage.save("other_fixture", profileID: second)
        try storage.save("rotated_fixture", profileID: first)
        XCTAssertEqual(try storage.load(profileID: first), "rotated_fixture")
        XCTAssertEqual(try storage.load(profileID: second), "other_fixture")
        try storage.delete(profileID: first)
        XCTAssertNil(try storage.load(profileID: first)); XCTAssertEqual(try storage.load(profileID: second), "other_fixture")
    }
}

@MainActor private final class ConnectionTestCache: StudioDashboardCaching {
    func load(profile: StudioProfile) throws -> StudioDashboardSnapshot? { nil }
    func save(_ snapshot: StudioDashboardSnapshot, profile: StudioProfile) throws {}
    func delete(profile: StudioProfile) throws {}
}
