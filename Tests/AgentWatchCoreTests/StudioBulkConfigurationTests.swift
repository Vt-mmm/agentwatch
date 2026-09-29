import XCTest
@testable import AgentWatchCore

final class StudioBulkConfigurationTests: XCTestCase {
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
        let p = try StudioClientConfiguration.prepareAll(tool: .pi, directory: dir, connection: profile, models: [a,b], helper: dir.appendingPathComponent("helper"), piCatalogModels: catalogs, piagentExtensions: [dir.appendingPathComponent("guard.ts")])
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
