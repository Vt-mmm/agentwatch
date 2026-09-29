import XCTest
@testable import AgentWatchCore

final class StudioClientConfigurationTests: XCTestCase {
    func root() throws -> URL {
        let url = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".cache/agentwatch-config-tests/" + UUID().uuidString)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: url) }; return url.resolvingSymlinksInPath()
    }
    func profile() throws -> StudioProfile { try .init(origin: StudioOrigin("http://127.0.0.1:17922"), id: String(repeating: "a", count: 64)) }
    func model(_ provider: String) -> StudioModel {
        var m = StudioModel(id: provider == "claude" ? "claude-local" : "gpt-6-luna", displayName: "Model", ownedBy: provider, nativeProtocol: provider == "claude" ? "messages" : "responses")
        m.providerModel = provider == "claude" ? "claude-haiku-4-5-20251001" : "gpt-6-luna"
        m.clientModel = m.providerModel; m.maxOutputTokens = 16384; m.contextMode = "provider_default"; return m
    }
    func testClaudeMergeReceiptRestoreAndNoContextOverride() throws {
        let dir = try root(), file = dir.appendingPathComponent("settings.json")
        let before = Data(#"{"env":{"KEEP":"yes","ANTHROPIC_API_KEY":"fake-old","ANTHROPIC_MODEL":"old-model","CLAUDE_CODE_AUTO_COMPACT_WINDOW":"100000"},"permissions":{"allow":[]}}"#.utf8)
        try before.write(to: file)
        let p = try StudioClientConfiguration.prepare(tool: .claude, directory: dir, connection: profile(), model: model("claude"), helper: dir.appendingPathComponent("helper with spaces"))
        let value = try XCTUnwrap(JSONSerialization.jsonObject(with: p.edits[0].after) as? [String: Any])
        let env = try XCTUnwrap(value["env"] as? [String: String])
        XCTAssertEqual(env["CLAUDE_CODE_MAX_OUTPUT_TOKENS"], "16384"); XCTAssertEqual(env["KEEP"], "yes"); XCTAssertNil(env["ANTHROPIC_API_KEY"]); XCTAssertNil(env["ANTHROPIC_MODEL"]); XCTAssertNil(env["CLAUDE_CODE_AUTO_COMPACT_WINDOW"])
        XCTAssertNotNil(value["permissions"]); XCTAssertFalse(String(decoding: p.edits[0].after, as: UTF8.self).contains("context_window"))
        let receipt = dir.appendingPathComponent("backup.json")
        try StudioClientConfiguration.saveReceipt(p, to: receipt)
        try StudioClientConfiguration.apply(p); try StudioClientConfiguration.restoreReceipt(at: receipt)
        XCTAssertEqual(try Data(contentsOf: file), before)
    }
    func testCodexPreservesUnrelatedTablesAndRestoresNativeContextDefaults() throws {
        let dir = try root(), file = dir.appendingPathComponent("config.toml")
        try Data("model = \"old\"\n[features]\nfoo = false\n".utf8).write(to: file)
        let p = try StudioClientConfiguration.prepare(tool: .codex, directory: dir, connection: profile(), model: model("codex"), helper: dir.appendingPathComponent("helper"))
        let text = String(decoding: p.edits[0].after, as: UTF8.self)
        XCTAssertTrue(text.contains("foo = false")); XCTAssertTrue(text.contains(".auth]")); XCTAssertFalse(text.contains("env_key")); XCTAssertFalse(text.contains("context_window"))
        try Data("model_context_window = 1000\n".utf8).write(to: file)
        XCTAssertThrowsError(try StudioClientConfiguration.apply(p))
        let reset = try StudioClientConfiguration.prepare(tool: .codex, directory: dir, connection: profile(), model: model("codex"), helper: dir)
        XCTAssertFalse(String(decoding: reset.edits[0].after, as: UTF8.self).contains("model_context_window"))
        try StudioClientConfiguration.apply(reset)
        try StudioClientConfiguration.restore(reset)
        XCTAssertEqual(String(decoding: try Data(contentsOf: file), as: UTF8.self), "model_context_window = 1000\n")
    }
    func testPiUsesNativeCatalogContextAndSessionExtension() throws {
        let dir = try root()
        let catalog = Data(#"{"id":"gpt-6-luna","contextWindow":272000,"maxTokens":128000,"reasoning":true}"#.utf8)
        let p = try StudioClientConfiguration.prepare(tool: .pi, directory: dir, connection: profile(), model: model("codex"), helper: dir.appendingPathComponent("helper"), piCatalogModel: catalog)
        try StudioClientConfiguration.apply(p)
        let json = String(decoding: try Data(contentsOf: dir.appendingPathComponent("models.json")), as: UTF8.self)
        XCTAssertTrue(json.contains("272000")); XCTAssertTrue(json.contains("128000"))
        XCTAssertTrue(FileManager.default.fileExists(atPath: dir.appendingPathComponent("agentwatch-studio-session.mjs").path))
        try StudioClientConfiguration.restore(p)
        XCTAssertFalse(FileManager.default.fileExists(atPath: dir.appendingPathComponent("models.json").path))
        XCTAssertThrowsError(try StudioClientConfiguration.prepare(tool: .pi, directory: dir, connection: profile(), model: model("codex"), helper: dir))
    }
    func testRestoreRefusesLaterUserEditAndSymlinks() throws {
        let dir = try root(), file = dir.appendingPathComponent("settings.json")
        let p = try StudioClientConfiguration.prepare(tool: .claude, directory: dir, connection: profile(), model: model("claude"), helper: dir)
        try StudioClientConfiguration.apply(p); try Data("{}".utf8).write(to: file)
        XCTAssertThrowsError(try StudioClientConfiguration.restore(p))
        let link = dir.appendingPathComponent("link")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: dir)
        XCTAssertThrowsError(try StudioClientConfiguration.prepare(tool: .claude, directory: link, connection: profile(), model: model("claude"), helper: dir))
    }
    func testReapplyKeepsFirstOriginalAndFailedApplyKeepsReceipt() throws {
        let dir = try root(), file = dir.appendingPathComponent("settings.json"), receipt = dir.appendingPathComponent("backup.json")
        let original = Data("{}".utf8)
        try original.write(to: file)
        let first = try StudioClientConfiguration.prepare(tool: .claude, directory: dir, connection: profile(), model: model("claude"), helper: dir)
        try StudioClientConfiguration.apply(first, receipt: receipt)
        var nextModel = model("claude"); nextModel.maxOutputTokens = 8192
        let second = try StudioClientConfiguration.prepare(tool: .claude, directory: dir, connection: profile(), model: nextModel, helper: dir)
        try StudioClientConfiguration.apply(second, receipt: receipt)
        let saved = try Data(contentsOf: receipt)
        try Data("user edit".utf8).write(to: file)
        XCTAssertThrowsError(try StudioClientConfiguration.apply(second, receipt: receipt))
        XCTAssertEqual(try Data(contentsOf: receipt), saved)
        try second.edits[0].after.write(to: file)
        try StudioClientConfiguration.restoreReceipt(at: receipt)
        XCTAssertEqual(try Data(contentsOf: file), original)

        let blocked = dir.appendingPathComponent("blocked")
        try Data().write(to: blocked)
        let failed = StudioConfigurationPlan(edits: [StudioConfigurationEdit(file: file, before: original, after: Data("changed".utf8)), StudioConfigurationEdit(file: blocked.appendingPathComponent("child"), before: nil, after: Data())], tool: .claude)
        XCTAssertThrowsError(try StudioClientConfiguration.apply(failed, receipt: receipt))
        XCTAssertEqual(try Data(contentsOf: file), original)
        XCTAssertFalse(FileManager.default.fileExists(atPath: receipt.path))
    }
}
