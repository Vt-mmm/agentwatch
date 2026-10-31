import XCTest
import CryptoKit
@testable import AgentWatchCore

private actor ManagedTransport: StudioHTTPTransport {
    var responses: [StudioHTTPResponse]
    var requests: [URLRequest] = []
    init(_ objects: [(Int, [String: Any])]) {
        responses = objects.map { StudioHTTPResponse(status: $0.0, body: try! JSONSerialization.data(withJSONObject: $0.1)) }
    }
    func send(_ request: URLRequest, origin: StudioOrigin) async throws -> StudioHTTPResponse {
        requests.append(request)
        guard !responses.isEmpty else { throw StudioError.serverUnavailable }
        return responses.removeFirst()
    }
    func captured() -> [URLRequest] { requests }
}

@MainActor final class StudioManagedTests: XCTestCase {
    let org = UUID(), owner = UUID(), team = UUID(), keyID = UUID(), instance = UUID(), epoch = UUID(), profileID = UUID(), deviceID = UUID(), runID = UUID(), mainID = UUID(), childID = UUID()
    func token(_ kind: String, _ id: UUID) -> String { "as_\(kind)_\(id.uuidString.lowercased())_" + String(repeating: "x", count: 43) }
    func configuration() throws -> (StudioProfile, StudioManifest) {
        let origin = try StudioOrigin("http://127.0.0.1:17921")
        let profile = try StudioProfile(origin: origin, id: origin.credentialSlotID(orgID: org, ownerID: owner, keyID: keyID, mode: .managed), connectionID: origin.profileID(orgID: org, ownerID: owner), keyID: keyID, credentialMode: .managed)
        let authority = StudioAuthority(instanceID: instance, epoch: epoch, generation: 1)
        let role = StudioHarnessRole(mode: "fixed", modelIDs: ["company-main"])
        let harness = StudioHarness(id: profileID, teamID: team, revision: 1, configuration: .init(main: role, research: role, review: nil))
        let user = StudioUser(id: owner, displayName: "Fixture", role: "member", active: true, version: 1, teamID: team)
        let manifest = StudioManifest(authority: authority, harness: harness, schemaVersion: 2, revision: String(repeating: "a", count: 64), orgID: org, user: user, keyID: keyID, credentialMode: .managed, expiresAt: Date().addingTimeInterval(3600), refreshSeconds: 300, models: [], codexCatalog: .object([:]))
        return (profile, manifest)
    }
    func grant(role: String = "main", fence: Int = 1, model: String = "company-main") -> [String: Any] {
        let id = role == "main" ? mainID : childID
        return ["run_id": runID.uuidString, "role_id": id.uuidString, "role": role,
            "model_id": model, "provider": "codex", "provider_model_id": "gpt-6-sol", "effort": "medium", "fence": fence,
            "token": token("run", id), "expires_at": "2026-01-01T00:00:00Z", "profile_id": profileID.uuidString,
            "studio_instance_id": instance.uuidString, "dataset_epoch": epoch.uuidString, "auth_generation": 1]
    }
    private func broker(_ transport: ManagedTransport) throws -> StudioManagedBroker {
        let (profile, manifest) = try configuration()
        let device = StudioManagedDevice(deviceID: deviceID, token: token("device", deviceID), expiresAt: Date(), instanceID: instance, epoch: epoch, generation: 1)
        return try StudioManagedBroker(profile: profile, manifest: manifest, device: device, client: StudioManagedClient(transport: transport))
    }
    func testSchemaAndCredentialModesCannotBeConfused() throws {
        let (profile, manifest) = try configuration()
        try manifest.validate(profile: profile)
        let direct = try StudioProfile(origin: profile.origin, id: profile.id, connectionID: profile.connectionID, keyID: keyID)
        XCTAssertThrowsError(try manifest.validate(profile: direct))
        XCTAssertTrue(StudioManagedClient.validToken(token("run", mainID), kind: "run", id: mainID))
        XCTAssertFalse(StudioManagedClient.validToken(token("device", mainID), kind: "run"))
        XCTAssertFalse(StudioManagedClient.validToken(token("run", mainID), kind: "run", id: childID))
    }
    func testBrokerKeepsDeviceCredentialPrivateAndPinsRoleAndAuthority() async throws {
        let transport = ManagedTransport([(201, grant()), (201, grant(role: "research")), (200, grant(fence: 2)), (204, [:])])
        let broker = try broker(transport)
        let main = try await broker.start(operation: UUID(), effort: "medium", taskClass: "standard")
        XCTAssertTrue(main.token.hasPrefix("as_run_"))
        do { _ = try await broker.start(operation: UUID(), effort: "medium", taskClass: "standard"); XCTFail("parallel root") } catch {}
        let child = try await broker.child(role: "research"); XCTAssertEqual(child.runID, main.runID)
        do { _ = try await broker.child(role: "research"); XCTFail("duplicate role") } catch {}
        let renewed = try await broker.renew(role: "main"); XCTAssertEqual(renewed.fence, 2)
        try await broker.close()
        let requests = await transport.captured()
        XCTAssertEqual(requests.count, 4)
        XCTAssertTrue(requests.allSatisfy { $0.value(forHTTPHeaderField: "Authorization") == "Bearer " + token("device", deviceID) })
        XCTAssertFalse(requests.contains { String(decoding: $0.httpBody ?? Data(), as: UTF8.self).contains("as_device_") })
        XCTAssertFalse(String(decoding: try JSONEncoder().encode(main), as: UTF8.self).contains(token("device", deviceID)))
    }
    /// Scout and verify reach the runtime with the Harness and the broker
    /// starts them as helpers; a role outside the Harness protocol is refused
    /// and a malformed scout role invalidates the manifest.
    func testScoutAndVerifyReachRuntimeAndRunAsHelpers() async throws {
        let (profile, base) = try configuration()
        let pool = StudioHarnessRole(mode: "auto", modelIDs: ["company-scout", "company-scout-old"])
        var config = StudioHarness.Configuration(main: StudioHarnessRole(mode: "fixed", modelIDs: ["company-main"]), research: pool, review: nil)
        config.scout = pool; config.verify = StudioHarnessRole(mode: "fixed", modelIDs: ["company-verify"])
        let manifest = { (config: StudioHarness.Configuration) in StudioManifest(authority: base.authority, harness: StudioHarness(id: self.profileID, teamID: self.team, revision: 3, configuration: config), schemaVersion: 2, revision: base.revision, orgID: self.org, user: base.user, keyID: self.keyID, credentialMode: .managed, expiresAt: base.expiresAt, refreshSeconds: 300, models: [], codexCatalog: .object([:])) }
        try manifest(config).validate(profile: profile)
        guard case .object(let out) = try StudioManagedBrokerCommand.configValue(manifest(config)), case .object(let h) = out["harness"], case .object(let c) = h["configuration"],
              case .object(let scout) = c["scout"], case .object(let verify) = c["verify"] else { return XCTFail("config shape") }
        XCTAssertEqual(scout["mode"].flatMap { if case .string(let s) = $0 { s } else { nil } }, "auto")
        XCTAssertEqual(verify["model_ids"].flatMap { if case .array(let a) = $0 { a.count } else { nil } }, 1)
        XCTAssertNil(c["review"], "a helper the Harness lacks is not sent")
        var bad = config; bad.scout = StudioHarnessRole(mode: "fixed", modelIDs: ["a", "b"])
        XCTAssertThrowsError(try manifest(bad).validate(profile: profile))
        let device = StudioManagedDevice(deviceID: deviceID, token: token("device", deviceID), expiresAt: Date(), instanceID: instance, epoch: epoch, generation: 1)
        let broker = try StudioManagedBroker(profile: profile, manifest: manifest(config), device: device,
                                             client: StudioManagedClient(transport: ManagedTransport([(201, grant()), (201, grant(role: "scout")), (201, grant(role: "verify"))])))
        _ = try await broker.start(operation: UUID(), effort: "medium", taskClass: "standard")
        let scouting = try await broker.child(role: "scout"), verifying = try await broker.child(role: "verify")
        XCTAssertEqual([scouting.role, verifying.role], ["scout", "verify"])
        do { _ = try await broker.child(role: "planner"); XCTFail("unknown helper role") } catch {}
    }
    /// API-key vendor models (DeepSeek…) reach Piagent through the same
    /// manifest and grants; a malformed vendor or protocol is still refused.
    func testAPIKeyVendorModelsAndGrantsAreAccepted() async throws {
        let (profile, base) = try configuration()
        func manifest(_ models: [StudioModel]) -> StudioManifest {
            StudioManifest(authority: base.authority, harness: base.harness, schemaVersion: 2, revision: base.revision, orgID: base.orgID, user: base.user, keyID: base.keyID, credentialMode: .managed, expiresAt: base.expiresAt, refreshSeconds: 300, models: models, codexCatalog: .object([:]))
        }
        let vendor = StudioModel(id: "deepseek-flash", displayName: "DeepSeek Flash", ownedBy: "deepseek", nativeProtocol: "chat", providerModel: "deepseek-flash", contextMode: "provider_default")
        try manifest([vendor]).validate(profile: profile)
        for bad in [StudioModel(id: "x", displayName: "x", ownedBy: "deepseek", nativeProtocol: "responses", contextMode: "provider_default"), StudioModel(id: "x", displayName: "x", ownedBy: "Deep Seek", nativeProtocol: "chat", contextMode: "provider_default"),
                    StudioModel(id: "x", displayName: "x", ownedBy: "claude", nativeProtocol: "chat", contextMode: "provider_default")] {
            XCTAssertThrowsError(try manifest([bad]).validate(profile: profile))
        }
        XCTAssertTrue(StudioVendor.valid("opencode-go")); XCTAssertFalse(StudioVendor.valid("codex")); XCTAssertFalse(StudioVendor.valid("x"))
        var vendorGrant = grant(); vendorGrant["provider"] = "deepseek"; vendorGrant["provider_model_id"] = "deepseek-flash"
        let transport = ManagedTransport([(201, vendorGrant)])
        let started = try await broker(transport).start(operation: UUID(), effort: "high", taskClass: "standard")
        XCTAssertEqual(started.provider, "deepseek")
        var bad = grant(); bad["provider"] = "Deep Seek"
        do { _ = try await broker(ManagedTransport([(201, bad)])).start(operation: UUID(), effort: "high", taskClass: "standard"); XCTFail("malformed vendor accepted") } catch {}
    }
    /// Role levels and the workflow reach the runtime unchanged; a process
    /// report is forwarded with the run's close only in its known shape, and
    /// only to a Studio that sent a workflow (an older one refuses the field).
    func testWorkflowReachesRuntimeAndProcessReportIsForwardedOnlyInShape() async throws {
        let (profile, base) = try configuration()
        let low = StudioHarnessRole(mode: "fixed", modelIDs: ["company-main"], effort: "low")
        let workflow = StudioWorkflow(plan: "suggest", verify: "require", review: "suggest", maxFixLoops: 2)
        var harness = StudioHarness(id: profileID, teamID: team, revision: 2, configuration: .init(main: low, research: low, review: nil, workflow: workflow))
        // Fast mode is the Harness's to allow: off (absent) unless Studio says so.
        guard case .object(let plain) = try StudioManagedBrokerCommand.configValue(StudioManifest(authority: base.authority, harness: harness, schemaVersion: 2, revision: base.revision, orgID: org, user: base.user, keyID: keyID, credentialMode: .managed, expiresAt: base.expiresAt, refreshSeconds: 300, models: [], codexCatalog: .object([:]))),
              case .object(let plainHarness) = plain["harness"], case .object(let plainConfig) = plainHarness["configuration"] else { return XCTFail("config shape") }
        XCTAssertNil(plainConfig["fast_mode"]); XCTAssertNil(plainConfig["bypass_mode"])
        let decoded = try JSONDecoder().decode(StudioHarness.Configuration.self, from: Data(#"{"main":{"mode":"fixed","model_ids":["company-main"],"effort":"low"},"research":{"mode":"fixed","model_ids":["company-main"],"effort":"low"},"workflow":{"plan":"suggest","verify":"require","review":"suggest","max_fix_loops":2},"fast_mode":true,"bypass_mode":false}"#.utf8))
        XCTAssertEqual(decoded.fastMode, true); XCTAssertEqual(decoded.bypassMode, false)
        harness = StudioHarness(id: profileID, teamID: team, revision: 2, configuration: decoded)
        let manifest = StudioManifest(authority: base.authority, harness: harness, schemaVersion: 2, revision: base.revision, orgID: org, user: base.user, keyID: keyID, credentialMode: .managed, expiresAt: base.expiresAt, refreshSeconds: 300, models: [], codexCatalog: .object([:]))
        try manifest.validate(profile: profile)
        guard case .object(let out) = try StudioManagedBrokerCommand.configValue(manifest), case .object(let h) = out["harness"], case .object(let c) = h["configuration"],
              case .object(let w) = c["workflow"], case .object(let r) = c["research"] else { return XCTFail("config shape") }
        XCTAssertEqual(w["verify"].flatMap { if case .string(let s) = $0 { s } else { nil } }, "require")
        XCTAssertEqual(w["max_fix_loops"].flatMap { if case .number(let n) = $0 { n } else { nil } }, 2)
        XCTAssertEqual(r["effort"].flatMap { if case .string(let s) = $0 { s } else { nil } }, "low")
        XCTAssertEqual(c["fast_mode"].flatMap { if case .bool(let b) = $0 { b } else { nil } }, true)
        XCTAssertEqual(c["bypass_mode"].flatMap { if case .bool(let b) = $0 { b } else { nil } }, false)
        guard case .array(let features) = out["broker_features"] else { return XCTFail("features") }
        XCTAssertEqual(features.count, 2)
        for bad in [StudioWorkflow(plan: "always", verify: "off", review: "off", maxFixLoops: 1), StudioWorkflow(plan: "off", verify: "off", review: "off", maxFixLoops: 4)] {
            let invalid = StudioHarness(id: profileID, teamID: team, revision: 2, configuration: .init(main: low, research: nil, review: nil, workflow: bad))
            XCTAssertThrowsError(try StudioManifest(authority: base.authority, harness: invalid, schemaVersion: 2, revision: base.revision, orgID: org, user: base.user, keyID: keyID, credentialMode: .managed, expiresAt: base.expiresAt, refreshSeconds: 300, models: [], codexCatalog: .object([:])).validate(profile: profile))
        }
        XCTAssertThrowsError(try StudioManifest(authority: base.authority, harness: StudioHarness(id: profileID, teamID: team, revision: 2, configuration: .init(main: StudioHarnessRole(mode: "fixed", modelIDs: ["m"], effort: "ultra"), research: nil, review: nil)), schemaVersion: 2, revision: base.revision, orgID: org, user: base.user, keyID: keyID, credentialMode: .managed, expiresAt: base.expiresAt, refreshSeconds: 300, models: [], codexCatalog: .object([:])).validate(profile: profile))

        let report: [String: Any] = ["version": 1, "policy": ["plan": "suggest", "verify": "require", "review": "suggest"], "changed": true, "plan_steps": 3, "plan_done": 2,
            "checks": 2, "checks_failed": 1, "verified": true, "reviews": 1, "reviewed": true, "blocking": 1, "blocking_open": 0, "fix_loops": 1, "outcome": "clean"]
        let parsed = try XCTUnwrap(try StudioManagedBrokerCommand.processValue(report))
        XCTAssertTrue(StudioProcessReport.valid(parsed))
        var withText = report; withText["prompt"] = "secret"
        XCTAssertFalse(StudioProcessReport.valid(try XCTUnwrap(try StudioManagedBrokerCommand.processValue(withText))))
        var textCount = report; textCount["checks"] = "npm test"
        XCTAssertFalse(StudioProcessReport.valid(try XCTUnwrap(try StudioManagedBrokerCommand.processValue(textCount))))
        var fraction = report; fraction["checks"] = 1.5
        XCTAssertFalse(StudioProcessReport.valid(try XCTUnwrap(try StudioManagedBrokerCommand.processValue(fraction))))
        XCTAssertThrowsError(try StudioManagedBrokerCommand.processValue("text"))
        // Version 2 (plan_skipped, unknown_tools) only for a Studio listing it,
        // and only in its own shape.
        var v2 = report; v2["version"] = 2; v2["plan_skipped"] = true; v2["unknown_tools"] = 2
        let parsedV2 = try XCTUnwrap(try StudioManagedBrokerCommand.processValue(v2))
        XCTAssertTrue(StudioProcessReport.valid(parsedV2, versions: [1, 2]))
        XCTAssertFalse(StudioProcessReport.valid(parsedV2))
        var v1Extra = report; v1Extra["plan_skipped"] = false
        XCTAssertFalse(StudioProcessReport.valid(try XCTUnwrap(try StudioManagedBrokerCommand.processValue(v1Extra)), versions: [1, 2]))
        var v2Missing = v2; v2Missing.removeValue(forKey: "unknown_tools")
        XCTAssertFalse(StudioProcessReport.valid(try XCTUnwrap(try StudioManagedBrokerCommand.processValue(v2Missing)), versions: [1, 2]))
        var v2Text = v2; v2Text["plan_skipped"] = "yes"
        XCTAssertFalse(StudioProcessReport.valid(try XCTUnwrap(try StudioManagedBrokerCommand.processValue(v2Text)), versions: [1, 2]))
        var v3 = v2; v3["version"] = 3
        XCTAssertFalse(StudioProcessReport.valid(try XCTUnwrap(try StudioManagedBrokerCommand.processValue(v3)), versions: [1, 2, 3]))
        // Version 3 adds helper objections and disagreements for the member; "disputed" exists only there.
        v3["objections"] = 2; v3["objections_answered"] = 1; v3["disputes"] = 1; v3["outcome"] = "disputed"
        let parsedV3 = try XCTUnwrap(try StudioManagedBrokerCommand.processValue(v3))
        XCTAssertTrue(StudioProcessReport.valid(parsedV3, versions: [1, 2, 3]))
        XCTAssertFalse(StudioProcessReport.valid(parsedV3, versions: [1, 2]))
        var v2Disputed = v2; v2Disputed["outcome"] = "disputed"
        XCTAssertFalse(StudioProcessReport.valid(try XCTUnwrap(try StudioManagedBrokerCommand.processValue(v2Disputed)), versions: [1, 2, 3]))
        var v3Text = v3; v3Text["disputes"] = "member decides"
        XCTAssertFalse(StudioProcessReport.valid(try XCTUnwrap(try StudioManagedBrokerCommand.processValue(v3Text)), versions: [1, 2, 3]))
        var all = manifest; all.processVersions = [1, 2, 3]
        guard case .object(let listedAll) = try StudioManagedBrokerCommand.configValue(all), case .array(let three) = listedAll["broker_features"] else { return XCTFail("features v3") }
        XCTAssertEqual(three.compactMap { if case .string(let s) = $0 { s } else { nil } }, ["process", "process-v2", "process-v3", "close-retry"])
        var listing = manifest; listing.processVersions = [1, 2]
        guard case .object(let listed) = try StudioManagedBrokerCommand.configValue(listing), case .array(let both) = listed["broker_features"] else { return XCTFail("features v2") }
        XCTAssertEqual(both.compactMap { if case .string(let s) = $0 { s } else { nil } }, ["process", "process-v2", "close-retry"])
        let v2Broker = try StudioManagedBroker(profile: profile, manifest: listing, device: StudioManagedDevice(deviceID: deviceID, token: token("device", deviceID), expiresAt: Date(), instanceID: instance, epoch: epoch, generation: 1),
            client: StudioManagedClient(transport: ManagedTransport([(201, grant()), (204, [:])])))
        _ = try await v2Broker.start(operation: UUID(), effort: "medium", taskClass: "standard")
        try await v2Broker.close(process: parsedV2)

        let device = StudioManagedDevice(deviceID: deviceID, token: token("device", deviceID), expiresAt: Date(), instanceID: instance, epoch: epoch, generation: 1)
        let current = ManagedTransport([(201, grant()), (204, [:])])
        let broker = try StudioManagedBroker(profile: profile, manifest: manifest, device: device, client: StudioManagedClient(transport: current))
        _ = try await broker.start(operation: UUID(), effort: "medium", taskClass: "standard")
        do { try await broker.close(process: ["version": .number(1)]); XCTFail("malformed report sent") } catch { XCTAssertEqual(error as? StudioError, .invalidResponse) }
        try await broker.close(process: parsed)
        let sent = await current.captured()
        XCTAssertEqual(sent.count, 2)
        let body = try XCTUnwrap(JSONSerialization.jsonObject(with: XCTUnwrap(sent.last?.httpBody)) as? [String: Any])
        XCTAssertEqual((body["process"] as? [String: Any])?["outcome"] as? String, "clean")

        // A Studio without a workflow gets the close without the report.
        let older = ManagedTransport([(201, grant()), (204, [:])])
        let oldBroker = try StudioManagedBroker(profile: profile, manifest: base, device: device, client: StudioManagedClient(transport: older))
        _ = try await oldBroker.start(operation: UUID(), effort: "medium", taskClass: "standard")
        try await oldBroker.close(process: parsed)
        let oldSent = await older.captured()
        let oldBody = try XCTUnwrap(JSONSerialization.jsonObject(with: XCTUnwrap(oldSent.last?.httpBody)) as? [String: Any])
        XCTAssertNil(oldBody["process"]); XCTAssertEqual(oldBody["role"] as? String, "")
    }
    /// A close Studio could not confirm (503 after Stop during a command)
    /// must not wedge the broker: the next start reaches Studio. Studio
    /// settles the unconfirmed run when its lease lapses.
    func testFailedCloseDoesNotBlockNextStart() async throws {
        let unavailable: [String: Any] = ["error": ["code": "managed_service_unavailable"]]
        let transport = ManagedTransport([(201, grant()), (503, unavailable), (201, grant()), (204, [:])])
        let broker = try broker(transport)
        _ = try await broker.start(operation: UUID(), effort: "medium", taskClass: "standard")
        do { try await broker.close(); XCTFail("failed close reported as closed") }
        catch { XCTAssertEqual((error as? StudioManagedRefusal)?.error, .serverUnavailable) }
        _ = try await broker.start(operation: UUID(), effort: "medium", taskClass: "standard")
        try await broker.close()
        // A start leaves the unconfirmed run to Studio: nothing more to close.
        try await broker.close()
        let paths = await transport.captured().compactMap { $0.url?.path }
        XCTAssertEqual(paths.count, 4)
        XCTAssertTrue(paths[2].hasSuffix("/managed/runs"))
    }
    /// The runtime asking again for a close Studio did not confirm reaches
    /// Studio again for the same run, so the runtime never reports a run
    /// closed that Studio never heard about (2026-10-22 audit).
    func testRetriedCloseReachesStudioAgain() async throws {
        let unavailable: [String: Any] = ["error": ["code": "managed_service_unavailable"]]
        let transport = ManagedTransport([(201, grant()), (503, unavailable), (503, unavailable), (204, [:])])
        let broker = try broker(transport)
        _ = try await broker.start(operation: UUID(), effort: "medium", taskClass: "standard")
        for _ in 0..<2 {
            do { try await broker.close(); XCTFail("failed close reported as closed") }
            catch { XCTAssertEqual((error as? StudioManagedRefusal)?.error, .serverUnavailable) }
        }
        try await broker.close()
        try await broker.close() // confirmed: nothing left
        let paths = await transport.captured().compactMap { $0.url?.path }
        XCTAssertEqual(paths.count, 4)
        XCTAssertEqual(Set(paths.dropFirst()).count, 1, "every close goes to the same run")
        XCTAssertTrue(paths[3].hasSuffix("/close"))
    }
    /// Studio refusing the process report keeps the run, so the runtime can
    /// close it without the report.
    func testRefusedReportKeepsRunForPlainClose() async throws {
        let refused: [String: Any] = ["error": ["code": "invalid_request"]]
        let transport = ManagedTransport([(201, grant()), (400, refused), (204, [:])])
        let broker = try broker(transport)
        _ = try await broker.start(operation: UUID(), effort: "medium", taskClass: "standard")
        let report = try XCTUnwrap(StudioManagedBrokerCommand.processValue(["version": 1, "policy": ["plan": "suggest", "verify": "suggest", "review": "off"], "changed": false,
            "plan_steps": 0, "plan_done": 0, "checks": 0, "checks_failed": 0, "verified": false, "reviews": 0, "reviewed": false, "blocking": 0, "blocking_open": 0, "fix_loops": 0, "outcome": "interrupted"]))
        do { try await broker.close(process: report); XCTFail("refused report reported as closed") } catch {}
        try await broker.close()
        let sent = await transport.captured()
        XCTAssertEqual(sent.count, 3)
        XCTAssertTrue(sent[2].url?.path.hasSuffix("/close") == true)
    }
    /// Up to three grants of one helper role at once: slot 1 keeps the role's
    /// key and opens with the old body; a slot past the first names itself and
    /// needs a Studio that offers that many; closing names the slot and keeps
    /// the others.
    func testHelperSlotsHoldSeveralGrantsOfOneRole() async throws {
        let (profile, base) = try configuration()
        var manifest = base; manifest.helperSlots = 3
        let device = StudioManagedDevice(deviceID: deviceID, token: token("device", deviceID), expiresAt: Date(), instanceID: instance, epoch: epoch, generation: 1)
        var second = grant(role: "research"); second["slot"] = 2
        var wrong = grant(role: "research"); wrong["slot"] = 2
        let transport = ManagedTransport([(201, grant()), (201, grant(role: "research")), (201, second), (200, { var g = second; g["fence"] = 2; return g }()), (204, [:]), (201, wrong), (204, [:])])
        let slots = try StudioManagedBroker(profile: profile, manifest: manifest, device: device, client: StudioManagedClient(transport: transport))
        _ = try await slots.start(operation: UUID(), effort: "medium", taskClass: "standard")
        let one = try await slots.child(role: "research"), two = try await slots.child(role: "research", slot: 2)
        XCTAssertNil(one.slot); XCTAssertEqual(two.slot, 2)
        do { _ = try await slots.child(role: "research", slot: 2); XCTFail("duplicate slot") } catch { XCTAssertEqual(error as? StudioError, .permissionDenied) }
        do { _ = try await slots.child(role: "research", slot: 4); XCTFail("slot out of range") } catch { XCTAssertEqual(error as? StudioError, .permissionDenied) }
        let renewed = try await slots.renew(role: "research", slot: 2); XCTAssertEqual(renewed.fence, 2)
        try await slots.close(role: "research", slot: 2)
        // Slot 1 is still held; slot 2 is free again, and Studio must grant the slot asked for.
        do { _ = try await slots.child(role: "research"); XCTFail("slot 1 was closed") } catch { XCTAssertEqual(error as? StudioError, .permissionDenied) }
        do { _ = try await slots.child(role: "research", slot: 3); XCTFail("wrong slot accepted") } catch { XCTAssertEqual(error as? StudioError, .invalidResponse) }
        try await slots.close(role: "research")
        let sent = await transport.captured()
        func body(_ i: Int) -> [String: Any] { (try? JSONSerialization.jsonObject(with: sent[i].httpBody ?? Data())) as? [String: Any] ?? [:] }
        XCTAssertEqual(body(1).keys.sorted(), ["role"], "slot 1 keeps the old body")
        XCTAssertEqual(body(2)["slot"] as? Int, 2)
        XCTAssertTrue(sent[3].url?.path.hasSuffix("/roles/\(childID.uuidString.lowercased())/renew") == true)
        XCTAssertEqual(body(4).keys.sorted(), ["role", "slot"]); XCTAssertEqual(body(4)["slot"] as? Int, 2)
        XCTAssertEqual(body(5)["slot"] as? Int, 3)
        XCTAssertEqual(body(6).keys.sorted(), ["role", "slot"]); XCTAssertEqual(body(6)["slot"] as? Int, 1, "closing slot 1 names it: Studio must not close the other slots")
        XCTAssertEqual(sent.count, 7)
        // An older Studio (no helper_slots) is never asked for a second slot.
        let oldTransport = ManagedTransport([(201, grant()), (201, grant(role: "research")), (204, [:])])
        let old = try broker(oldTransport)
        _ = try await old.start(operation: UUID(), effort: "medium", taskClass: "standard")
        do { _ = try await old.child(role: "research", slot: 2); XCTFail("slot without helper_slots") } catch { XCTAssertEqual(error as? StudioError, .permissionDenied) }
        _ = try await old.child(role: "research"); try await old.close(role: "research")
        let oldSent = await oldTransport.captured()
        XCTAssertEqual(((try? JSONSerialization.jsonObject(with: oldSent[2].httpBody ?? Data())) as? [String: Any])?.keys.sorted(), ["role"], "an older Studio takes no slot field")
        var two2 = base; two2.helperSlots = 2
        let limited = try StudioManagedBroker(profile: profile, manifest: two2, device: device, client: StudioManagedClient(transport: ManagedTransport([(201, grant())])))
        _ = try await limited.start(operation: UUID(), effort: "medium", taskClass: "standard")
        do { _ = try await limited.child(role: "research", slot: 3); XCTFail("slot past helper_slots") } catch { XCTAssertEqual(error as? StudioError, .permissionDenied) }
        do { try await limited.close(role: "main", slot: 2); XCTFail("slot on whole-run close") } catch { XCTAssertEqual(error as? StudioError, .permissionDenied) }
        // Features advertise helper-slots only for a Studio with two or more.
        func features(_ m: StudioManifest) throws -> [String] {
            guard case .object(let out) = try StudioManagedBrokerCommand.configValue(m), case .array(let list) = out["broker_features"] else { return [] }
            return list.compactMap { if case .string(let s) = $0 { s } else { nil } }
        }
        XCTAssertEqual(try features(manifest), ["process", "close-retry", "helper-slots"])
        XCTAssertEqual(try features(base), ["process", "close-retry"])
        var single = base; single.helperSlots = 1
        XCTAssertFalse(try features(single).contains("helper-slots"))
        guard case .object(let out) = try StudioManagedBrokerCommand.configValue(manifest) else { return XCTFail("config") }
        XCTAssertEqual(out["helper_slots"].flatMap { if case .number(let n) = $0 { n } else { nil } }, 3)
        let decoded = try StudioClient.apiDecoder().decode(StudioManifest.self, from: JSONEncoder().encode(StudioManagedBrokerCommand.configValue(manifest)))
        XCTAssertEqual(decoded.helperSlots, 3)
        // The command protocol takes an integer slot 1...3 only.
        XCTAssertEqual(try StudioManagedBrokerCommand.slotValue(nil), 1)
        for raw in ["{\"slot\":1}", "{\"slot\":3}", "{\"slot\":2.0}"] {
            let message = try JSONSerialization.jsonObject(with: Data(raw.utf8)) as! [String: Any]
            XCTAssertNoThrow(try StudioManagedBrokerCommand.slotValue(message["slot"]), raw)
        }
        for raw in ["{\"slot\":0}", "{\"slot\":4}", "{\"slot\":1.5}", "{\"slot\":\"2\"}", "{\"slot\":true}", "{\"slot\":null}", "{\"slot\":-1}"] {
            let message = try JSONSerialization.jsonObject(with: Data(raw.utf8)) as! [String: Any]
            XCTAssertThrowsError(try StudioManagedBrokerCommand.slotValue(message["slot"]), raw)
        }
    }
    func testRenewCannotChangePinnedModel() async throws {
        let transport = ManagedTransport([(201, grant()), (200, grant(fence: 2, model: "other-account"))])
        let broker = try broker(transport)
        _ = try await broker.start(operation: UUID(), effort: "medium", taskClass: "simple")
        do { _ = try await broker.renew(role: "main"); XCTFail("changed route accepted") } catch { XCTAssertEqual(error as? StudioError, .identityChanged) }
    }
    func testRefusalKeepsStudiosReasonAndNamesTheMachine() async throws {
        let transport = ManagedTransport([(201, grant()), (409, ["error": ["code": "harness_profile_unavailable", "message": "harness_profile_unavailable"]]), (409, ["error": ["code": "Not A Code!"]])])
        let broker = try broker(transport)
        _ = try await broker.start(operation: UUID(), effort: "medium", taskClass: "simple")
        do { _ = try await broker.child(role: "research"); XCTFail("refusal accepted") }
        catch { XCTAssertEqual(error as? StudioManagedRefusal, StudioManagedRefusal(error: .identityChanged, code: "harness_profile_unavailable")) }
        // A body that is not Studio's error shape keeps the coarse error.
        do { _ = try await broker.child(role: "research"); XCTFail("refusal accepted") } catch { XCTAssertEqual(error as? StudioError, .identityChanged) }
        let sent = await transport.captured()
        XCTAssertEqual(sent.first?.value(forHTTPHeaderField: StudioMachine.header), StudioMachine.current)
        XCTAssertEqual(StudioMachine.name(" MacBook của Vũ\n"), "MacBook%20c%E1%BB%A7a%20V%C5%A9")
        XCTAssertNil(StudioMachine.name("  "))
    }
    /// Pinned runtime, Pi SDK and helper fixtures under a disposable folder.
    func managedRuntime() throws -> (base: URL, runtime: URL, entry: URL, pi: URL, helper: URL, dir: URL) {
        let base = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".cache/watch-managed-import-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: base) }
        let runtime = base.appendingPathComponent("runtime"), sdk = base.appendingPathComponent("sdk"), dir = base.appendingPathComponent("agent")
        for path in [runtime.appendingPathComponent("scripts"), sdk.appendingPathComponent("dist/cli"), dir] {
            try FileManager.default.createDirectory(at: path, withIntermediateDirectories: true)
        }
        let entry = runtime.appendingPathComponent("scripts/piagent-studio.mjs"), pi = sdk.appendingPathComponent("dist/cli/index.js"), helper = base.appendingPathComponent("agentwatch")
        for (file, content) in [(entry, "#!/usr/bin/env node\nconsole.log('fixture');\n"), (pi, "#!/bin/sh\nexit 0\n"), (helper, "#!/bin/sh\nexit 0\n")] {
            try Data(content.utf8).write(to: file); try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: file.path)
        }
        try Data(#"{"version":"0.87.1"}"#.utf8).write(to: sdk.appendingPathComponent("package.json"))
        return (base, runtime, entry, pi, helper, dir)
    }
    func testManagedImportPinsBothRuntimePartsAndPreservesOtherClientFiles() async throws {
        let (base, runtime, entry, pi, helper, dir) = try managedRuntime()
        let personal = Data(#"{"providers":{"personal":{}}}"#.utf8)
        try personal.write(to: dir.appendingPathComponent("models.json"))
        let (profile, manifest) = try configuration()
        let plan = try StudioManagedConfiguration.prepare(directory: dir, connection: profile, manifest: manifest, helper: helper, runtimeRoot: runtime, piExecutable: pi)
        XCTAssertEqual(plan.edits.count, 1)
        XCTAssertEqual(plan.edits[0].file.lastPathComponent, "agent-watch-managed.json")
        let text = String(decoding: plan.edits[0].after, as: UTF8.self)
        XCTAssertFalse(text.contains("as_live_")); XCTAssertFalse(text.contains("as_device_")); XCTAssertFalse(text.contains("as_run_"))
        XCTAssertTrue(text.contains("node_sha256")); XCTAssertTrue(text.contains("entrypoint_sha256"))
        let receipt = base.appendingPathComponent("receipt.json")
        try StudioClientConfiguration.apply(plan, receipt: receipt)
        try await StudioManagedConfiguration.authorize(directory: dir, profileID: profile.id)
        XCTAssertEqual(try Data(contentsOf: dir.appendingPathComponent("models.json")), personal)
        let launch = try StudioManagedConfiguration.terminal(directory: dir, project: base, profileID: profile.id, launchDirectory: base.appendingPathComponent("launches"))
        XCTAssertTrue(try String(contentsOf: launch.url, encoding: .utf8).contains("env -i"))
        launch.discard()
        XCTAssertThrowsError(try StudioManagedConfiguration.terminal(directory: dir, project: base, profileID: String(repeating: "f", count: 64), launchDirectory: base.appendingPathComponent("launches")))
        try Data("#!/usr/bin/env node\nchanged\n".utf8).write(to: entry)
        XCTAssertThrowsError(try StudioManagedConfiguration.terminal(directory: dir, project: base, profileID: profile.id, launchDirectory: base.appendingPathComponent("launches")))
    }
    func testPiBindingCarriesOnlyWhatTheBrokerNeedsAndLeavesPiFilesAlone() throws {
        let (_, _, _, _, helper, dir) = try managedRuntime()
        let settings = Data(#"{"packages":["x"]}"#.utf8), models = Data(#"{"providers":{"personal":{}}}"#.utf8)
        try settings.write(to: dir.appendingPathComponent("settings.json")); try models.write(to: dir.appendingPathComponent("models.json"))
        let (profile, manifest) = try configuration()
        let plan = try StudioManagedConfiguration.prepareStudioBinding(directory: dir, connection: profile, manifest: manifest, helper: helper)
        XCTAssertEqual(plan.edits.map(\.file.lastPathComponent), ["agent-watch-studio.json"])
        let object = try StudioClientConfiguration.object(plan.edits[0].after)
        XCTAssertEqual(Set(object.keys), ["schema_version", "profile_id", "origin", "broker", "broker_sha256", "configuration_revision"])
        XCTAssertEqual(object["profile_id"] as? String, profile.id)
        XCTAssertEqual(object["broker"] as? String, helper.resolvingSymlinksInPath().path)
        let receipt = dir.appendingPathComponent("receipt.json")
        try StudioClientConfiguration.apply(plan, receipt: receipt)
        XCTAssertEqual(try Data(contentsOf: dir.appendingPathComponent("settings.json")), settings)
        XCTAssertEqual(try Data(contentsOf: dir.appendingPathComponent("models.json")), models)
        XCTAssertFalse(FileManager.default.fileExists(atPath: dir.appendingPathComponent("agent-watch-managed.json").path))
        let direct = try StudioProfile(origin: profile.origin, id: String(repeating: "a", count: 64))
        XCTAssertThrowsError(try StudioManagedConfiguration.prepareStudioBinding(directory: dir, connection: direct, manifest: manifest, helper: helper))
    }
    /// An app update replaces the broker the Pi binding pins: the binding is
    /// stale at once (the five-second watch resyncs), and the rewrite pins the new hash.
    func testPiBindingGoesStaleWhenAnAppUpdateReplacesTheBroker() throws {
        let (_, _, _, _, helper, dir) = try managedRuntime()
        XCTAssertNil(StudioManagedConfiguration.studioBindingStaleFingerprint(directory: dir), "no binding, nothing to resync")
        let (profile, manifest) = try configuration()
        let receipt = StudioManagedConfiguration.studioReceiptURL(directory: dir)
        addTeardownBlock { try? FileManager.default.removeItem(at: receipt) }
        try StudioClientConfiguration.apply(StudioManagedConfiguration.prepareStudioBinding(directory: dir, connection: profile, manifest: manifest, helper: helper), receipt: receipt)
        XCTAssertNil(StudioManagedConfiguration.studioBindingStaleFingerprint(directory: dir))
        Thread.sleep(forTimeInterval: 1.1)
        try Data("#!/bin/sh\necho next-watch\n".utf8).write(to: helper)
        XCTAssertNotNil(StudioManagedConfiguration.studioBindingStaleFingerprint(directory: dir), "a replaced broker makes the Pi binding stale")
        try StudioClientConfiguration.apply(StudioManagedConfiguration.prepareStudioBinding(directory: dir, connection: profile, manifest: manifest, helper: helper), receipt: receipt)
        XCTAssertNil(StudioManagedConfiguration.studioBindingStaleFingerprint(directory: dir))
        let written = try StudioClientConfiguration.object(StudioClientConfiguration.read(dir.appendingPathComponent("agent-watch-studio.json")))
        XCTAssertEqual(written["broker_sha256"] as? String, SHA256.hash(data: try Data(contentsOf: helper)).map { String(format: "%02x", $0) }.joined())
    }
    func testCompanyKeySyncsPiAndPiagentInOneFolderEachOnItsOwn() async throws {
        @MainActor final class Key: StudioKeyStorage {
            func load(profileID: String) -> String? { "fixture-key" }
            func save(_ key: String, profileID: String) {}
            func delete(profileID: String) {}
        }
        let (_, _, _, _, helper, dir) = try managedRuntime()
        let (profile, manifest) = try configuration()
        let encoder = JSONEncoder(); encoder.dateEncodingStrategy = .iso8601
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: encoder.encode(manifest)) as? [String: Any])
        let suite = "studio-managed-both-" + UUID().uuidString, defaults = UserDefaults(suiteName: suite)!
        let receipts = [StudioManagedConfiguration.receiptURL(directory: dir), StudioManagedConfiguration.studioReceiptURL(directory: dir)]
        defer { defaults.removePersistentDomain(forName: suite); receipts.forEach { try? FileManager.default.removeItem(at: $0) } }
        let settings = StudioPreferences(defaults: defaults); settings.save(profile)
        let store = StudioSyncStore(defaults: defaults, client: StudioClient(transport: ManagedTransport([(200, object)])), settings: settings, keys: Key())
        store.activateProfile(); store.directories = ["pi": dir.path, "piagent": dir.path]; store.selected = [.pi, .piagent]
        await store.synchronize(helper: helper, force: true)
        XCTAssertEqual(store.results.first { $0.target == .pi }?.success, true)
        XCTAssertTrue(FileManager.default.fileExists(atPath: dir.appendingPathComponent("agent-watch-studio.json").path))
        let piagent = try XCTUnwrap(store.results.first { $0.target == .piagent })
        XCTAssertFalse(piagent.message.hasPrefix("Dùng chung"), "Piagent is synced on its own, not skipped as the twin of Pi in the same folder")
    }
    /// The Pi host the installed Piagent pins is the one the import accepts:
    /// 1.3.0 for Piagent 1.33+, 0.87.1 before (no pin read); never a host the
    /// Piagent does not pin, nor one Agent Watch was not checked against.
    func testManagedImportAcceptsThePiHostPiagentPins() throws {
        let (_, runtime, _, pi, helper, dir) = try managedRuntime()
        let sdk = pi.deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let (profile, manifest) = try configuration()
        let prepare = { try StudioManagedConfiguration.prepare(directory: dir, connection: profile, manifest: manifest, helper: helper, runtimeRoot: runtime, piExecutable: pi) }
        let write = { (file: URL, json: String) in try Data(json.utf8).write(to: file) }
        // Piagent 1.33: pins Pi 1.3.0.
        try write(runtime.appendingPathComponent("package.json"), #"{"name":"@piagent/platform","version":"1.33.0","peerDependencies":{"@earendil-works/pi-coding-agent":"1.3.0"}}"#)
        XCTAssertThrowsError(try prepare(), "Pi 0.87.1 under a Piagent that pins 1.3.0") { XCTAssertEqual($0 as? StudioCLIError, .unsupportedVersion) }
        try write(sdk.appendingPathComponent("package.json"), #"{"version":"1.3.0"}"#)
        XCTAssertNoThrow(try prepare())
        XCTAssertEqual(StudioInstallLocations.pinnedPiVersion(piagentRoot: runtime), "1.3.0")
        // A pin Agent Watch was not checked against is refused.
        try write(runtime.appendingPathComponent("package.json"), #"{"name":"@piagent/platform","version":"9.0.0","peerDependencies":{"@earendil-works/pi-coding-agent":"9.9.9"}}"#)
        try write(sdk.appendingPathComponent("package.json"), #"{"version":"9.9.9"}"#)
        XCTAssertThrowsError(try prepare()) { XCTAssertEqual($0 as? StudioCLIError, .unsupportedVersion) }
        // An older Piagent without the pin readable: 0.87.1 as before.
        try FileManager.default.removeItem(at: runtime.appendingPathComponent("package.json"))
        try write(sdk.appendingPathComponent("package.json"), #"{"version":"0.87.1"}"#)
        XCTAssertNoThrow(try prepare())
    }
    /// A Piagent update replaces the launcher the binding pins: the binding is
    /// stale (Watch resyncs at once) until it is written again.
    func testBindingGoesStaleWhenAPiagentUpdateReplacesTheLauncher() throws {
        let (base, runtime, entry, pi, helper, dir) = try managedRuntime()
        XCTAssertFalse(StudioManagedConfiguration.bindingStale(directory: dir), "no binding, nothing to resync")
        let (profile, manifest) = try configuration()
        let receipt = base.appendingPathComponent("receipt.json")
        try StudioClientConfiguration.apply(StudioManagedConfiguration.prepare(directory: dir, connection: profile, manifest: manifest, helper: helper, runtimeRoot: runtime, piExecutable: pi), receipt: receipt)
        XCTAssertFalse(StudioManagedConfiguration.bindingStale(directory: dir))
        try Data("#!/usr/bin/env node\nconsole.log('next release');\n".utf8).write(to: entry)
        XCTAssertTrue(StudioManagedConfiguration.bindingStale(directory: dir))
        let first = StudioManagedConfiguration.staleFingerprint(directory: dir)
        try Data("#!/usr/bin/env node\nconsole.log('the release after');\n".utf8).write(to: entry)
        XCTAssertNotNil(first); XCTAssertNotEqual(StudioManagedConfiguration.staleFingerprint(directory: dir), first, "another update is synced at once")
        try StudioClientConfiguration.apply(StudioManagedConfiguration.prepare(directory: dir, connection: profile, manifest: manifest, helper: helper, runtimeRoot: runtime, piExecutable: pi), receipt: receipt)
        XCTAssertNil(StudioManagedConfiguration.staleFingerprint(directory: dir))
        // An Agent Watch update replaces the broker the binding pins.
        Thread.sleep(forTimeInterval: 1.1)
        try Data("#!/bin/sh\necho next-watch\n".utf8).write(to: helper)
        XCTAssertNotNil(StudioManagedConfiguration.staleFingerprint(directory: dir), "a replaced broker is stale")
        try StudioClientConfiguration.apply(StudioManagedConfiguration.prepare(directory: dir, connection: profile, manifest: manifest, helper: helper, runtimeRoot: runtime, piExecutable: pi), receipt: receipt)
        XCTAssertFalse(StudioManagedConfiguration.bindingStale(directory: dir))
    }
    func testNewCompanyKeyTakesOverTheImportOfADisconnectedKey() throws {
        let (_, runtime, _, pi, helper, dir) = try managedRuntime()
        let receipt = StudioManagedConfiguration.receiptURL(directory: dir)
        addTeardownBlock { try? FileManager.default.removeItem(at: receipt) }
        let (old, manifest) = try configuration()
        let fresh = try StudioProfile(origin: old.origin, id: String(repeating: "9", count: 64), connectionID: old.connectionID, keyID: UUID(), credentialMode: .managed)
        let other = try StudioManifest(authority: manifest.authority, harness: manifest.harness, schemaVersion: 2, revision: manifest.revision, orgID: org, user: manifest.user,
            keyID: XCTUnwrap(fresh.keyID), credentialMode: .managed, expiresAt: manifest.expiresAt, refreshSeconds: 300, models: [], codexCatalog: .object([:]))
        try StudioClientConfiguration.apply(StudioManagedConfiguration.prepare(directory: dir, connection: old, manifest: manifest, helper: helper, runtimeRoot: runtime, piExecutable: pi), receipt: receipt)
        XCTAssertThrowsError(try StudioManagedConfiguration.prepare(directory: dir, connection: fresh, manifest: other, helper: helper, runtimeRoot: runtime, piExecutable: pi)) {
            XCTAssertEqual($0 as? StudioConfigurationError, .destinationInUse)
        }
        // The old key was disconnected: only the new slot is saved.
        XCTAssertTrue(try StudioClientConfiguration.adoptOrphanedReceipt(receipt, owner: fresh.id, savedProfiles: [fresh.id]))
        try StudioClientConfiguration.apply(StudioManagedConfiguration.prepare(directory: dir, connection: fresh, manifest: other, helper: helper, runtimeRoot: runtime, piExecutable: pi), receipt: receipt)
        let binding = try StudioClientConfiguration.object(Data(contentsOf: dir.appendingPathComponent("agent-watch-managed.json")))
        XCTAssertEqual(binding["profile_id"] as? String, fresh.id)
    }

}
