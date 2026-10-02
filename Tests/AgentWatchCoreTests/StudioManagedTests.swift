import XCTest
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
        let harness = StudioHarness(id: profileID, teamID: team, revision: 2, configuration: .init(main: low, research: low, review: nil, workflow: workflow))
        let manifest = StudioManifest(authority: base.authority, harness: harness, schemaVersion: 2, revision: base.revision, orgID: org, user: base.user, keyID: keyID, credentialMode: .managed, expiresAt: base.expiresAt, refreshSeconds: 300, models: [], codexCatalog: .object([:]))
        try manifest.validate(profile: profile)
        guard case .object(let out) = try StudioManagedBrokerCommand.configValue(manifest), case .object(let h) = out["harness"], case .object(let c) = h["configuration"],
              case .object(let w) = c["workflow"], case .object(let r) = c["research"] else { return XCTFail("config shape") }
        XCTAssertEqual(w["verify"].flatMap { if case .string(let s) = $0 { s } else { nil } }, "require")
        XCTAssertEqual(w["max_fix_loops"].flatMap { if case .number(let n) = $0 { n } else { nil } }, 2)
        XCTAssertEqual(r["effort"].flatMap { if case .string(let s) = $0 { s } else { nil } }, "low")
        guard case .array(let features) = out["broker_features"] else { return XCTFail("features") }
        XCTAssertEqual(features.count, 1)
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
        var listing = manifest; listing.processVersions = [1, 2]
        guard case .object(let listed) = try StudioManagedBrokerCommand.configValue(listing), case .array(let both) = listed["broker_features"] else { return XCTFail("features v2") }
        XCTAssertEqual(both.compactMap { if case .string(let s) = $0 { s } else { nil } }, ["process", "process-v2"])
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
    func testRenewCannotChangePinnedModel() async throws {
        let transport = ManagedTransport([(201, grant()), (200, grant(fence: 2, model: "other-account"))])
        let broker = try broker(transport)
        _ = try await broker.start(operation: UUID(), effort: "medium", taskClass: "simple")
        do { _ = try await broker.renew(role: "main"); XCTFail("changed route accepted") } catch { XCTAssertEqual(error as? StudioError, .identityChanged) }
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
