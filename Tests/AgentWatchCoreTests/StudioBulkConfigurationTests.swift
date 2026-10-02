import XCTest
@testable import AgentWatchCore

final class StudioBulkConfigurationTests: XCTestCase {
    func testAnotherCredentialCannotOverwriteOrDisableExistingClientBinding() throws {
        let dir = try folder(), first = try StudioProfile(origin: StudioOrigin("https://studio.test"), id: String(repeating: "a", count: 64))
        let second = try StudioProfile(origin: first.origin, id: String(repeating: "b", count: 64))
        let receipt = StudioClientConfiguration.receiptURL(tool: .claude, directory: dir)
        addTeardownBlock { try? FileManager.default.removeItem(at: receipt) }
        let plan = try StudioClientConfiguration.prepareAll(tool: .claude, directory: dir, connection: first, models: [model("claude", "fixture-model")], helper: dir)
        // Old releases didn't store profileID in the receipt. Recognize the
        // generated credential argument without changing ownership.
        var legacy = plan; legacy.profileID = nil
        try StudioClientConfiguration.apply(legacy, receipt: receipt)
        XCTAssertEqual(StudioClientConfiguration.bindingOwners(legacy), [first.id])
        let before = try Data(contentsOf: dir.appendingPathComponent("settings.json"))
        XCTAssertThrowsError(try StudioClientConfiguration.prepareAll(tool: .claude, directory: dir, connection: second, models: [model("claude", "fixture-model")], helper: dir)) {
            XCTAssertEqual($0 as? StudioConfigurationError, .destinationInUse)
        }
        XCTAssertThrowsError(try StudioClientConfiguration.prepareDisabled(tool: .claude, directory: dir, connection: second))
        XCTAssertEqual(try Data(contentsOf: dir.appendingPathComponent("settings.json")), before)
        let update = try StudioClientConfiguration.prepareAll(tool: .claude, directory: dir, connection: first, models: [model("claude", "fixture-model")], helper: dir)
        try StudioClientConfiguration.apply(update, receipt: receipt)
        let managed = try StudioProfile(origin: first.origin, id: String(repeating: "c", count: 64), keyID: UUID(), credentialMode: .managed)
        XCTAssertThrowsError(try StudioClientConfiguration.prepareAll(tool: .claude, directory: dir, connection: managed, models: [model("claude", "fixture-model")], helper: dir))
        try StudioClientConfiguration.restoreReceipt(at: receipt)
    }
    func testDisconnectedSlotReceiptIsTakenOverOnlyWhenNoSavedSlotOwnsIt() throws {
        let dir = try folder(), origin = try StudioOrigin("https://studio.test")
        let old = try StudioProfile(origin: origin, id: String(repeating: "a", count: 64))
        let fresh = try StudioProfile(origin: origin, id: String(repeating: "b", count: 64))
        let receipt = StudioClientConfiguration.receiptURL(tool: .claude, directory: dir)
        addTeardownBlock { try? FileManager.default.removeItem(at: receipt) }
        let settingsFile = dir.appendingPathComponent("settings.json"), personal = Data(#"{"theme":"dark"}"#.utf8)
        try personal.write(to: settingsFile)
        let models = [model("claude", "fixture-model")]
        try StudioClientConfiguration.apply(StudioClientConfiguration.prepareAll(tool: .claude, directory: dir, connection: old, models: models, helper: dir), receipt: receipt)
        // Both slots saved: the folder still belongs to the other key.
        XCTAssertFalse(try StudioClientConfiguration.adoptOrphanedReceipt(receipt, owner: fresh.id, savedProfiles: [old.id, fresh.id]))
        XCTAssertThrowsError(try StudioClientConfiguration.prepareAll(tool: .claude, directory: dir, connection: fresh, models: models, helper: dir)) {
            XCTAssertEqual($0 as? StudioConfigurationError, .destinationInUse)
        }
        XCTAssertFalse(try StudioClientConfiguration.adoptOrphanedReceipt(receipt, owner: fresh.id, savedProfiles: [old.id]), "Only a saved slot can take over")
        // The old slot was disconnected, but its files were edited afterwards.
        let imported = try Data(contentsOf: settingsFile)
        try Data(#"{"edited":true}"#.utf8).write(to: settingsFile)
        XCTAssertThrowsError(try StudioClientConfiguration.adoptOrphanedReceipt(receipt, owner: fresh.id, savedProfiles: [fresh.id])) {
            XCTAssertEqual($0 as? StudioConfigurationError, .changed)
        }
        try imported.write(to: settingsFile)
        XCTAssertTrue(try StudioClientConfiguration.adoptOrphanedReceipt(receipt, owner: fresh.id, savedProfiles: [fresh.id]))
        XCTAssertFalse(try StudioClientConfiguration.adoptOrphanedReceipt(receipt, owner: fresh.id, savedProfiles: [fresh.id]), "Already owned")
        try StudioClientConfiguration.apply(StudioClientConfiguration.prepareAll(tool: .claude, directory: dir, connection: fresh, models: models, helper: dir), receipt: receipt)
        XCTAssertTrue(String(decoding: try Data(contentsOf: settingsFile), as: UTF8.self).contains(fresh.id))
        // Restore still returns to the state before Agent Watch's first import.
        try StudioClientConfiguration.restoreReceipt(at: receipt)
        XCTAssertEqual(try Data(contentsOf: settingsFile), personal)
    }
    func testUnknownLegacyReceiptIsNeverTakenOver() throws {
        let dir = try folder(), fresh = try StudioProfile(origin: StudioOrigin("https://studio.test"), id: String(repeating: "b", count: 64))
        let file = dir.appendingPathComponent("settings.json"), receipt = dir.appendingPathComponent("legacy-receipt.json")
        let edit = StudioConfigurationEdit(file: file, before: nil, after: Data(#"{"apiKeyHelper":"unknown"}"#.utf8))
        try StudioClientConfiguration.apply(StudioConfigurationPlan(edits: [edit], tool: .claude), receipt: receipt)
        XCTAssertFalse(try StudioClientConfiguration.adoptOrphanedReceipt(receipt, owner: fresh.id, savedProfiles: [fresh.id]))
        XCTAssertNil(try JSONDecoder().decode(StudioConfigurationPlan.self, from: Data(contentsOf: receipt)).profileID)
    }
    func folder() throws -> URL {
        let url = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".cache/agentwatch-bulk-test-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: url) }; return url
    }
    func model(_ provider: String, _ name: String) -> StudioModel {
        StudioModel(id: name, displayName: name, ownedBy: provider, nativeProtocol: provider == "claude" ? "messages" : "responses", providerModel: name, clientModel: name, maxOutputTokens: 16384, outputAccounting: provider == "claude" ? "provider_cap" : "usage_settlement", contextMode: "provider_default")
    }
    func testPiImportsBothFamiliesAndPreservesPersonalModelsAndExtensions() throws {
        let dir = try folder(), profile = try StudioProfile(origin: StudioOrigin("http://127.0.0.1:17922"), id: String(repeating: "a", count: 64))
        let a = model("claude", "claude-haiku-4-5-20251001"), b = model("codex", "gpt-6-luna")
        try Data(#"{"extensions":["personal.mjs"],"enabledModels":["personal/x"]}"#.utf8).write(to: dir.appendingPathComponent("settings.json"))
        let before = Data(#"{"providers":{"personal":{"models":[{"id":"x"}]}}}"#.utf8)
        try before.write(to: dir.appendingPathComponent("models.json"))
        let catalogs = Dictionary(uniqueKeysWithValues: [a,b].map { ($0.id, Data("{\"id\":\"\($0.id)\",\"contextWindow\":272000,\"maxTokens\":128000}".utf8)) })
        let receipt = dir.appendingPathComponent("receipt.json")
        // An API-key vendor model runs only in company Piagent sessions; a direct key's Pi config leaves it out.
        let vendor = StudioModel(id: "deepseek-flash", displayName: "DeepSeek Flash", ownedBy: "deepseek", nativeProtocol: "chat", providerModel: "deepseek-flash", clientModel: "deepseek-flash", maxOutputTokens: 16384, outputAccounting: "provider_cap", contextMode: "provider_default")
        let p = try StudioClientConfiguration.prepareAll(tool: .pi, directory: dir, connection: profile, models: [a,b,vendor], helper: dir.appendingPathComponent("helper"), piCatalogModels: catalogs, piagentExtensions: [dir.appendingPathComponent("guard.ts")])
        try StudioClientConfiguration.apply(p, receipt: receipt)
        let json = try StudioClientConfiguration.object(Data(contentsOf: dir.appendingPathComponent("models.json")))
        XCTAssertEqual((json["providers"] as? [String: Any])?.count, 3)
        let settings = try StudioClientConfiguration.object(Data(contentsOf: dir.appendingPathComponent("settings.json")))
        XCTAssertEqual((settings["enabledModels"] as? [String])?.count, 3)
        XCTAssertTrue((settings["extensions"] as? [String])?.contains("personal.mjs") == true)
        let next = try StudioClientConfiguration.prepareAll(tool: .pi, directory: dir, connection: profile, models: [b], helper: dir.appendingPathComponent("helper"), piCatalogModels: catalogs)
        try StudioClientConfiguration.apply(next, receipt: receipt)
        let changed = try StudioClientConfiguration.object(Data(contentsOf: dir.appendingPathComponent("models.json")))
        XCTAssertNil((changed["providers"] as? [String: Any])?["agent_watch_claude"])
        try StudioClientConfiguration.restoreReceipt(at: receipt)
        XCTAssertEqual(try Data(contentsOf: dir.appendingPathComponent("models.json")), before)
    }
    func testCodexCatalogPreservesNativeContextAndRejectsMissingMetadata() throws {
        let dir = try folder(), profile = try StudioProfile(origin: StudioOrigin("https://studio.test"), id: String(repeating: "b", count: 64))
        let m = model("codex", "gpt-6-luna")
        let first = try StudioClientConfiguration.prepare(tool: .codex, directory: dir, connection: profile, model: m, helper: dir)
        let receipt = dir.appendingPathComponent("receipt.json")
        try StudioClientConfiguration.apply(first, receipt: receipt)
        let catalog = Data(#"{"models":[{"slug":"gpt-6-luna","context_window":272000,"auto_compact_token_limit":258400},{"slug":"ungranted","context_window":900000}]}"#.utf8)
        let all = try StudioClientConfiguration.prepareAll(tool: .codex, directory: dir, connection: profile, models: [m], helper: dir, codexCatalog: catalog)
        try StudioClientConfiguration.apply(all, receipt: receipt)
        let json = String(decoding: try Data(contentsOf: dir.appendingPathComponent("agentwatch-models.json")), as: UTF8.self)
        XCTAssertTrue(json.contains("272000")); XCTAssertFalse(json.contains("ungranted"))
        let config = String(decoding: try Data(contentsOf: dir.appendingPathComponent("config.toml")), as: UTF8.self)
        XCTAssertFalse(config.contains("model_context_window")); XCTAssertTrue(config.contains("model_catalog_json"))
        XCTAssertThrowsError(try StudioClientConfiguration.prepareAll(tool: .codex, directory: dir, connection: profile, models: [model("codex", "unknown")], helper: dir, codexCatalog: catalog))
        try StudioClientConfiguration.restoreReceipt(at: receipt)
        XCTAssertFalse(FileManager.default.fileExists(atPath: dir.appendingPathComponent("config.toml").path))
    }
    func testClaudeOnlyReceivesGrantedClaudeNames() throws {
        let dir = try folder(), profile = try StudioProfile(origin: StudioOrigin("https://studio.test"), id: String(repeating: "c", count: 64))
        let plan = try StudioClientConfiguration.prepareAll(tool: .claude, directory: dir, connection: profile, models: [model("claude", "claude-haiku-4-5-20251001"), model("codex", "gpt-6-luna")], helper: dir)
        let settings = try StudioClientConfiguration.object(plan.edits[0].after)
        XCTAssertEqual(settings["availableModels"] as? [String], ["claude-haiku-4-5-20251001"])
        XCTAssertEqual((settings["env"] as? [String: String])?["ANTHROPIC_BASE_URL"], "https://studio.test/claude")
    }
}

extension StudioBulkConfigurationTests {
    func testGrantRemovalDisablesStudioWithoutRestoringPersonalBilling() throws {
        let dir = try folder(), profile = try StudioProfile(origin: StudioOrigin("https://studio.test"), id: String(repeating: "d", count: 64))
        let receipt = StudioClientConfiguration.receiptURL(tool: .claude, directory: dir)
        addTeardownBlock { try? FileManager.default.removeItem(at: receipt) }
        let m = model("claude", "claude-haiku-4-5-20251001")
        let original = Data(#"{"env":{"ANTHROPIC_BASE_URL":"https://personal.test"}}"#.utf8)
        try original.write(to: dir.appendingPathComponent("settings.json"))
        let p = try StudioClientConfiguration.prepareAll(tool: .claude, directory: dir, connection: profile, models: [m], helper: dir)
        try StudioClientConfiguration.apply(p, receipt: receipt)
        let disabled = try XCTUnwrap(StudioClientConfiguration.prepareDisabled(tool: .claude, directory: dir))
        try StudioClientConfiguration.apply(disabled, receipt: receipt)
        let json = try StudioClientConfiguration.object(Data(contentsOf: dir.appendingPathComponent("settings.json")))
        XCTAssertEqual(json["apiKeyHelper"] as? String, "/usr/bin/false")
        XCTAssertEqual((json["env"] as? [String: String])?["ANTHROPIC_BASE_URL"], "https://studio.test/claude")
        let restoredGrant = try StudioClientConfiguration.prepareAll(tool: .claude, directory: dir, connection: profile, models: [m], helper: dir)
        try StudioClientConfiguration.apply(restoredGrant, receipt: receipt)
        try StudioClientConfiguration.restoreReceipt(at: receipt)
        XCTAssertEqual(try Data(contentsOf: dir.appendingPathComponent("settings.json")), original)
    }
}
