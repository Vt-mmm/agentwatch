import Foundation

extension StudioClientConfiguration {
    /// One plan owns the full granted model set for a selected CLI. No inference.
    public static func prepareAll(tool: StudioConfiguredTool, directory: URL, connection: StudioProfile,
                                  models: [StudioModel], helper: URL, codexCatalog: Data? = nil,
                                  piCatalogModels: [String: Data] = [:], piagentExtensions: [URL] = []) throws -> StudioConfigurationPlan {
        let compatible = models.filter { tool == .pi || $0.ownedBy == tool.rawValue }
        guard !compatible.isEmpty, compatible.allSatisfy({ $0.clientModel != nil && $0.clientModel == $0.providerModel }) else { throw StudioConfigurationError.nativeModelUnavailable }
        // Keep a member's default when it remains granted.
        let settings = try object(read(directory.appendingPathComponent("settings.json")))
        let wanted = settings[tool == .pi ? "defaultModel" : "model"] as? String
        let chosen = compatible.first(where: { $0.clientModel == wanted }) ?? compatible[0]
        let initial = try prepare(tool: tool, directory: directory, connection: connection, model: chosen, helper: helper, piCatalogModel: piCatalogModels[chosen.id])
        var edits = initial.edits
        func replaceJSON(_ name: String, _ update: (inout [String: Any]) throws -> Void) throws {
            guard let i = edits.firstIndex(where: { $0.file.lastPathComponent == name }) else { throw StudioConfigurationError.invalid }
            let old = edits[i]; var value = try object(old.after); try update(&value)
            edits[i] = StudioConfigurationEdit(file: old.file, before: old.before, after: try encoded(value))
        }
        switch tool {
        case .claude:
            try replaceJSON("settings.json") { value in
                value["availableModels"] = compatible.map(\.cliModelID)
                var env = value["env"] as? [String: Any] ?? [:]
                env["ANTHROPIC_BASE_URL"] = connection.origin.value + "/claude"
                env["CLAUDE_CODE_ENABLE_GATEWAY_MODEL_DISCOVERY"] = "1"
                for family in ["HAIKU", "SONNET", "OPUS"] {
                    env["ANTHROPIC_DEFAULT_" + family + "_MODEL"] = compatible.first(where: { $0.cliModelID.contains(family.lowercased()) })?.cliModelID ?? chosen.cliModelID
                }
                // Keep the entire selected set usable; Studio enforces each request's cap.
                env["CLAUDE_CODE_MAX_OUTPUT_TOKENS"] = String(min(compatible.compactMap(\.maxOutputTokens).min() ?? 16384, 32000))
                value["env"] = env
            }
        case .codex:
            guard let codexCatalog, let entries = try object(codexCatalog)["models"] as? [[String: Any]] else { throw StudioConfigurationError.missingCatalog }
            let allowed = Set(compatible.map(\.cliModelID)), filtered = entries.filter { allowed.contains($0["slug"] as? String ?? "") }
            guard Set(filtered.compactMap { $0["slug"] as? String }) == allowed,
                  filtered.allSatisfy({ ($0["context_window"] as? Int ?? 0) > 0 }) else { throw StudioConfigurationError.missingCatalog }
            let file = directory.appendingPathComponent("agentwatch-models.json")
            edits.append(StudioConfigurationEdit(file: file, before: try read(file), after: try encoded(["models": filtered])))
            let old = edits[0]
            let previous = old.before.flatMap { String(data: $0, encoding: .utf8) } ?? ""
            let selected = compatible.first { previous.contains("model = " + toml($0.cliModelID)) } ?? chosen
            var config = String(decoding: old.after, as: UTF8.self)
            config = config.replacingOccurrences(of: "model = " + toml(chosen.cliModelID) + "\n", with: "model = " + toml(selected.cliModelID) + "\n")
            config = "model_catalog_json = " + toml(file.path) + "\n" + config
            edits[0] = StudioConfigurationEdit(file: old.file, before: old.before, after: Data(config.utf8))
        case .pi:
            try replaceJSON("models.json") { value in
                var providers = value["providers"] as? [String: Any] ?? [:]
                providers.removeValue(forKey: "agent_watch_claude"); providers.removeValue(forKey: "agent_watch_codex")
                for family in ["claude", "codex"] {
                    let group = compatible.filter { $0.ownedBy == family }; if group.isEmpty { continue }
                    var nativeModels: [[String: Any]] = []
                    for model in group {
                        guard let data = piCatalogModels[model.id] else { throw StudioConfigurationError.missingCatalog }
                        var native = try object(data)
                        guard native["id"] as? String == model.providerModel, (native["contextWindow"] as? Int ?? 0) > 0,
                              let max = native["maxTokens"] as? Int, max > 0 else { throw StudioConfigurationError.missingCatalog }
                        native["id"] = model.cliModelID
                        if family == "claude" { native["maxTokens"] = min(max, Int(model.maxOutputTokens ?? 16384)) }
                        for key in ["baseUrl", "provider", "api"] { native.removeValue(forKey: key) }
                        if var compat = native["compat"] as? [String: Any] { compat.removeValue(forKey: "allowedFallbackModels"); native["compat"] = compat }
                        nativeModels.append(native)
                    }
                    providers["agent_watch_" + family] = ["baseUrl": connection.origin.value + (family == "codex" ? "/v1" : "/claude"), "api": family == "codex" ? "openai-responses" : "anthropic-messages", "apiKey": "!" + shellQuote(helper.path) + " credential --profile " + shellQuote(connection.id), "models": nativeModels]
                }
                value["providers"] = providers
            }
            try replaceJSON("settings.json") { value in
                var extensions = value["extensions"] as? [String] ?? []
                for url in piagentExtensions where !extensions.contains(url.path) { extensions.append(url.path) }
                value["extensions"] = extensions
                let prior = settings["enabledModels"] as? [String] ?? []
                value["enabledModels"] = prior.filter { !$0.hasPrefix("agent_watch_") } + compatible.map { "agent_watch_" + $0.ownedBy + "/" + $0.cliModelID }
            }
        }
        return StudioConfigurationPlan(edits: edits, tool: tool)
    }
}

extension StudioClientConfiguration {
    public static func piagentExtensions(home: URL = FileManager.default.homeDirectoryForCurrentUser) throws -> [URL] {
        for bin in [home.appendingPathComponent(".local/bin/piagent"), URL(fileURLWithPath: "/opt/homebrew/bin/piagent"), URL(fileURLWithPath: "/usr/local/bin/piagent")] {
            guard FileManager.default.isExecutableFile(atPath: bin.path) else { continue }
            let root = bin.resolvingSymlinksInPath().deletingLastPathComponent().deletingLastPathComponent()
            let package = try object(read(root.appendingPathComponent("package.json")))
            guard package["name"] as? String == "@piagent/platform", let config = package["pi"] as? [String: Any],
                  let extensions = config["extensions"] as? [String], !extensions.isEmpty else { continue }
            return try extensions.map { name in
                let url = root.appendingPathComponent(name).standardizedFileURL
                guard url.path.hasPrefix(root.path + "/"), try read(url) != nil else { throw StudioConfigurationError.unsafe }
                return url
            }
        }
        throw StudioConfigurationError.unsupported
    }
}

extension StudioClientConfiguration {
    /// Keep the Studio endpoint in place but remove its selectable models and
    /// disable its helper, so loss of grants cannot fall back to personal billing.
    public static func prepareDisabled(tool: StudioConfiguredTool, directory: URL) throws -> StudioConfigurationPlan? {
        let receipt = receiptURL(tool: tool, directory: directory)
        guard let data = try read(receipt) else { return nil }
        let old = try JSONDecoder().decode(StudioConfigurationPlan.self, from: data)
        var edits: [StudioConfigurationEdit] = []
        for previous in old.edits {
            guard let before = try read(previous.file), before == previous.after else { throw StudioConfigurationError.changed }
            var after = before
            switch previous.file.lastPathComponent {
            case "settings.json":
                var value = try object(before)
                if tool == .claude { value["availableModels"] = []; value["apiKeyHelper"] = "/usr/bin/false" }
                if tool == .pi { value["enabledModels"] = (value["enabledModels"] as? [String] ?? []).filter { !$0.hasPrefix("agent_watch_") } }
                after = try encoded(value)
            case "models.json":
                var value = try object(before), providers = value["providers"] as? [String: Any] ?? [:]
                providers.removeValue(forKey: "agent_watch_claude"); providers.removeValue(forKey: "agent_watch_codex"); value["providers"] = providers
                after = try encoded(value)
            case "agentwatch-models.json": after = try encoded(["models": []])
            case "config.toml":
                let text = String(decoding: before, as: UTF8.self)
                let lines = text.components(separatedBy: "\n").map { $0.hasPrefix("args = [\"credential\"") ? "args = [\"credential\", \"--unavailable\"]" : $0 }
                after = Data(lines.joined(separator: "\n").utf8)
            default: break
            }
            edits.append(StudioConfigurationEdit(file: previous.file, before: before, after: after))
        }
        return StudioConfigurationPlan(edits: edits, tool: tool)
    }
}
