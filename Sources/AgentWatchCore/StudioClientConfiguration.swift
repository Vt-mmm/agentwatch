import Foundation
import CryptoKit
import Darwin

public enum StudioConfiguredTool: String, CaseIterable, Codable, Sendable { case claude, codex, pi }
public enum StudioConfigurationError: Error, LocalizedError {
    case invalid, unsupported, changed, unsafe, missingCatalog, nativeModelUnavailable, destinationInUse
    public var errorDescription: String? {
        switch self {
        case .invalid: "Cấu hình hoặc model không hợp lệ. Kết nối lại Studio để lấy giới hạn mới."
        case .unsupported: "File cấu hình có cấu trúc chưa hỗ trợ ghép an toàn. Chọn thư mục profile khác."
        case .changed: "File đã thay đổi sau lần kiểm tra. Tải lại trước khi áp dụng hoặc khôi phục."
        case .unsafe: "Đường dẫn cấu hình không an toàn hoặc không có quyền ghi."
        case .missingCatalog: "CLI chưa có bộ thông số tương thích cho model này. Cần cập nhật bộ model đã được kiểm chứng."
        case .nativeModelUnavailable: "Studio chưa xác minh được tên model gốc. Làm mới danh sách model trước khi cấu hình CLI."
        case .destinationInUse: "Thư mục đang dùng key khác. Chọn thư mục riêng hoặc khôi phục cấu hình của key cũ trước."
        }
    }
}
public struct StudioConfigurationEdit: Codable, Sendable {
    public let file: URL
    public let before: Data?
    public let after: Data
}
public struct StudioConfigurationPlan: Codable, Sendable {
    public let edits: [StudioConfigurationEdit]
    public let tool: StudioConfiguredTool
    public var profileID: String? = nil
}

/// Pure preparation, followed by explicit application from the UI. No key is
/// serialized. Context is left to Claude/Codex; Pi copies its native catalog.
public enum StudioClientConfiguration {
    static func shellQuote(_ value: String) -> String { "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'" }
    static func toml(_ value: String) -> String { StudioCLIProfiles.quoted(value) }
    static func checked(_ file: URL) throws {
        guard file.isFileURL, !file.pathComponents.contains("..") else { throw StudioConfigurationError.unsafe }
        var path = URL(fileURLWithPath: "/")
        for part in file.pathComponents.dropFirst() {
            path.appendPathComponent(part)
            if let values = try? path.resourceValues(forKeys: [.isSymbolicLinkKey]), values.isSymbolicLink == true { throw StudioConfigurationError.unsafe }
        }
    }
    static func read(_ file: URL) throws -> Data? {
        try checked(file)
        guard FileManager.default.fileExists(atPath: file.path) else { return nil }
        let values = try file.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey])
        guard values.isRegularFile == true, (values.fileSize ?? Int.max) <= 2_097_152 else { throw StudioConfigurationError.unsafe }
        return try Data(contentsOf: file)
    }
    static func object(_ data: Data?) throws -> [String: Any] {
        guard let data else { return [:] }
        guard let value = try JSONSerialization.jsonObject(with: data) as? [String: Any] else { throw StudioConfigurationError.unsupported }
        return value
    }
    static func encoded(_ object: [String: Any]) throws -> Data {
        try JSONSerialization.data(withJSONObject: object, options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]) + Data([10])
    }
    public static func prepare(tool: StudioConfiguredTool, directory: URL, connection: StudioProfile,
                               model: StudioModel, helper: URL, piCatalogModel: Data? = nil) throws -> StudioConfigurationPlan {
        guard connection.credentialMode == .direct else { throw StudioError.permissionDenied }
        try validateBinding(connection: connection, tool: tool, directory: directory)
        guard ["claude", "codex"].contains(model.ownedBy), let cap = model.maxOutputTokens, cap > 0,
              model.contextMode == "provider_default", !model.id.isEmpty,
              !helper.path.contains("\n"), helper.isFileURL else { throw StudioConfigurationError.invalid }
        guard let clientModel = model.clientModel, clientModel == model.providerModel else { throw StudioConfigurationError.nativeModelUnavailable }
        let credential = shellQuote(helper.path) + " credential --profile " + shellQuote(connection.id)
        var edits: [StudioConfigurationEdit] = []
        func jsonEdit(_ name: String, update: (inout [String: Any]) throws -> Void) throws {
            let file = directory.appendingPathComponent(name), before = try read(file)
            var content = try object(before); try update(&content)
            edits.append(StudioConfigurationEdit(file: file, before: before, after: try encoded(content)))
        }
        switch tool {
        case .claude:
            guard model.ownedBy == "claude" else { throw StudioConfigurationError.invalid }
            try jsonEdit("settings.json") { content in
                var env = content["env"] as? [String: Any] ?? [:]
                env.removeValue(forKey: "ANTHROPIC_API_KEY"); env.removeValue(forKey: "ANTHROPIC_AUTH_TOKEN")
                for key in ["ANTHROPIC_MODEL", "CLAUDE_CODE_OAUTH_TOKEN", "CLAUDE_CODE_USE_BEDROCK", "CLAUDE_CODE_USE_VERTEX", "CLAUDE_CODE_USE_FOUNDRY"] { env.removeValue(forKey: key) }
                for key in ["CLAUDE_CODE_AUTO_COMPACT_WINDOW", "CLAUDE_AUTOCOMPACT_PCT_OVERRIDE", "CLAUDE_CODE_MAX_CONTEXT_TOKENS", "CLAUDE_CODE_DISABLE_1M_CONTEXT", "CLAUDE_CODE_DISABLE_UNKNOWN_MODEL_WINDOW_ENFORCEMENT", "DISABLE_COMPACT"] { env.removeValue(forKey: key) }
                content.removeValue(forKey: "autoCompactWindow")
                env["ANTHROPIC_BASE_URL"] = connection.origin.value
                env["CLAUDE_CODE_MAX_OUTPUT_TOKENS"] = String(min(cap, 32000))
                content["env"] = env; content["apiKeyHelper"] = credential; content["model"] = clientModel
            }
        case .codex:
            guard model.ownedBy == "codex" else { throw StudioConfigurationError.invalid }
            let file = directory.appendingPathComponent("config.toml"), before = try read(file)
            guard before == nil || String(data: before!, encoding: .utf8) != nil else { throw StudioConfigurationError.unsupported }
            var previous = before.flatMap { String(data: $0, encoding: .utf8) } ?? ""
            let begin = "# AgentWatch Studio begin", end = "# AgentWatch Studio end"
            if let a = previous.range(of: begin), let b = previous.range(of: end), a.lowerBound < b.lowerBound {
                previous.removeSubrange(a.lowerBound..<b.upperBound)
            }
            // Refuse ambiguous multiline/inline provider definitions rather than
            // pretending a line edit is a general TOML parser.
            guard !previous.contains("\"\"\""), !previous.contains("'''"),
                  !previous.contains("model_providers ="), !previous.contains("model_providers.agent_watch") else { throw StudioConfigurationError.unsupported }
            var section = false
            var lines: [String] = []
            for line in previous.components(separatedBy: "\n") {
                let trimmed = line.trimmingCharacters(in: .whitespaces)
                if trimmed.hasPrefix("[") {
                    let normalized = trimmed.filter { !$0.isWhitespace && $0 != "\"" && $0 != "'" }
                    guard !normalized.contains("model_providers.agent_watch") else { throw StudioConfigurationError.unsupported }
                    section = true
                }
                if !section, !trimmed.hasPrefix("#"), let equal = trimmed.firstIndex(of: "=") {
                    let key = trimmed[..<equal].trimmingCharacters(in: .whitespaces)
                    guard key.range(of: "^[A-Za-z0-9_-]+$", options: .regularExpression) != nil, key != "model_providers" else { throw StudioConfigurationError.unsupported }
                    if ["model", "model_provider", "model_catalog_json"].contains(key) { continue }
                    if ["model_context_window", "model_auto_compact_token_limit"].contains(key) { continue }
                    if key == "profile" { throw StudioConfigurationError.unsupported }
                }
                lines.append(line)
            }
            let config = "model = \(toml(clientModel))\nmodel_provider = \"agent_watch\"\n" + lines.joined(separator: "\n") + "\n# AgentWatch Studio begin\n[model_providers.agent_watch]\nname = \"Agent Studio\"\nbase_url = \(toml(connection.origin.value + "/v1"))\nwire_api = \"responses\"\nrequest_max_retries = 0\nstream_max_retries = 0\n[model_providers.agent_watch.auth]\ncommand = \(toml(helper.path))\nargs = [\"credential\", \"--profile\", \(toml(connection.id))]\n# AgentWatch Studio end\n"
            edits.append(StudioConfigurationEdit(file: file, before: before, after: Data(config.utf8)))
        case .pi:
            guard let piCatalogModel, var native = try JSONSerialization.jsonObject(with: piCatalogModel) as? [String: Any],
                  native["id"] as? String == model.providerModel,
                  let context = native["contextWindow"] as? Int, context > 0,
                  let output = native["maxTokens"] as? Int, output > 0 else { throw StudioConfigurationError.missingCatalog }
            // Keep catalog context, reasoning/input and compatibility metadata.
            native["id"] = clientModel; native["maxTokens"] = model.ownedBy == "codex" ? output : min(output, Int(cap))
            native.removeValue(forKey: "baseUrl"); native.removeValue(forKey: "provider"); native.removeValue(forKey: "api")
            // Cross-provider fallback is not authorized by a Studio key.
            if var compat = native["compat"] as? [String: Any] { compat.removeValue(forKey: "allowedFallbackModels"); native["compat"] = compat }
            let provider = "agent_watch_" + model.ownedBy
            try jsonEdit("models.json") { content in
                var providers = content["providers"] as? [String: Any] ?? [:]
                providers[provider] = ["baseUrl": connection.origin.value + (model.ownedBy == "codex" ? "/v1" : ""), "api": model.ownedBy == "codex" ? "openai-responses" : "anthropic-messages", "apiKey": "!" + credential, "models": [native]]
                content["providers"] = providers
            }
            let extensionFile = directory.appendingPathComponent("agentwatch-studio-session.mjs")
            let extensionData = Data("""
            export default function (pi) {
              pi.on("before_provider_request", (event, ctx) => {
                if (ctx.model?.provider === "agent_watch_codex") {
                  const payload = { ...event.payload };
                  delete payload.max_output_tokens;
                  return payload;
                }
              });
              pi.on("before_provider_headers", (event, ctx) => {
                if (!ctx.model?.provider?.startsWith("agent_watch_")) return;
                const id = ctx.sessionManager.getSessionId();
                if (!id) throw new Error("Studio requires a stable Pi session ID");
                event.headers["X-Session-Id"] = id;
              });
            }
            """.utf8)
            let previousExtension = try read(extensionFile)
            guard previousExtension == nil || previousExtension == extensionData else { throw StudioConfigurationError.changed }
            edits.append(StudioConfigurationEdit(file: extensionFile, before: previousExtension, after: extensionData))
            try jsonEdit("settings.json") { content in
                var extensions = content["extensions"] as? [String] ?? []
                if !extensions.contains(extensionFile.path) { extensions.append(extensionFile.path) }
                content["extensions"] = extensions
                content["defaultProvider"] = provider; content["defaultModel"] = clientModel
                content["enabledModels"] = [provider + "/" + clientModel]
            }
        }
        return StudioConfigurationPlan(edits: edits, tool: tool, profileID: connection.id)
    }
    /// The Pi host, wherever the member's npm installed it; the qualified
    /// version wins when several are installed.
    public static func piExecutable(home: URL = FileManager.default.homeDirectoryForCurrentUser,
                                    system: [URL] = ["/opt/homebrew", "/usr/local"].map { URL(fileURLWithPath: $0) }) throws -> URL {
        let prefixes = [home.appendingPathComponent(".pi/npm-global"), home.appendingPathComponent(".local")] + system
            + StudioInstallLocations.userPrefixes(home: home, package: "@earendil-works/pi-coding-agent") + StudioInstallLocations.versionManagedPrefixes(home: home)
        let found = prefixes.map { $0.appendingPathComponent("bin/pi") }.filter { FileManager.default.isExecutableFile(atPath: $0.path) }
        let root = { (pi: URL) in pi.resolvingSymlinksInPath().deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent() }
        guard let pi = found.first(where: { StudioInstallLocations.packageField(root($0), "version") == "0.87.1" }) ?? found.first else { throw StudioConfigurationError.missingCatalog }
        return pi
    }
    public static func catalogModel(for model: StudioModel, piExecutable: URL) throws -> Data {
        let cli = piExecutable.resolvingSymlinksInPath()
        // Tested Pi 0.87 layout; refuse guesses for another package layout.
        let root = cli.deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let package = try object(read(root.appendingPathComponent("package.json")))
        guard package["version"] as? String == "0.87.1" else { throw StudioConfigurationError.missingCatalog }
        let provider = model.ownedBy == "claude" ? "anthropic" : "openai-codex"
        let file = root.appendingPathComponent("node_modules/@earendil-works/pi-ai/dist/providers/data/\(provider).json")
        let catalog = try object(read(file))
        for value in catalog.values {
            if let models = value as? [String: Any], let native = models[model.providerModel ?? model.id] as? [String: Any] { return try encoded(native) }
        }
        // Reviewed addition absent from Pi 0.87.1. The native catalog always
        // wins once it advertises this ID; never infer an unknown model's limits.
        // https://platform.claude.com/docs/en/models/sonnet-5-5/overview
        if provider == "anthropic", model.providerModel == "claude-sonnet-5-5" {
            return Data(Self.sonnet55Catalog.utf8)
        }
        throw StudioConfigurationError.missingCatalog
    }
    static let sonnet55Catalog = #"{"id":"claude-sonnet-5-5","name":"Claude Sonnet 5.5","reasoning":true,"input":["text","image"],"cost":{"input":2,"output":10,"cacheRead":0.2,"cacheWrite":2.5},"contextWindow":1000000,"maxTokens":128000,"thinkingLevelMap":{"off":null,"minimal":null,"low":"low","medium":"medium","high":"high","xhigh":"xhigh","max":"max"},"compat":{"forceAdaptiveThinking":true,"supportsTemperature":false,"supportsStrictTools":true},"promptCache":{"short":300,"long":3600}}"#
    static func privateWrite(_ data: Data, to file: URL, exclusive: Bool = false) throws {
        let temporary = exclusive ? file : file.deletingLastPathComponent().appendingPathComponent(".agentwatch-" + UUID().uuidString)
        let fd = Darwin.open(temporary.path, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW, 0o600)
        guard fd >= 0 else { throw StudioConfigurationError.unsafe }
        let handle = FileHandle(fileDescriptor: fd, closeOnDealloc: true)
        do {
            try handle.write(contentsOf: data); try handle.synchronize(); try handle.close()
            if !exclusive, Darwin.rename(temporary.path, file.path) != 0 { throw StudioConfigurationError.unsafe }
        } catch { try? handle.close(); try? FileManager.default.removeItem(at: temporary); throw error }
    }
    public static func receiptURL(tool: StudioConfiguredTool, directory: URL) -> URL {
        let digest = SHA256.hash(data: Data((tool.rawValue + "\0" + directory.path).utf8)).map { String(format: "%02x", $0) }.joined()
        return FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("AgentWatch/StudioConfigurationBackups/\(digest).json")
    }
    public static func saveReceipt(_ plan: StudioConfigurationPlan, to file: URL) throws {
        try checked(file)
        var receipt = plan
        if let previous = try read(file) {
            let old = try JSONDecoder().decode(StudioConfigurationPlan.self, from: previous)
            if let expected = plan.profileID {
                guard bindingOwners(old) == [expected] else { throw StudioConfigurationError.destinationInUse }
            } else if old.profileID != nil { throw StudioConfigurationError.destinationInUse }
            guard old.tool == plan.tool, Set(old.edits.map(\.file)).isSubset(of: Set(plan.edits.map(\.file))) else { throw StudioConfigurationError.changed }
            var merged: [StudioConfigurationEdit] = []
            for edit in plan.edits {
                if let original = old.edits.first(where: { $0.file == edit.file }) {
                    guard edit.before == original.after else { throw StudioConfigurationError.changed }
                    merged.append(StudioConfigurationEdit(file: edit.file, before: original.before, after: edit.after))
                } else { merged.append(edit) }
            }
            receipt = StudioConfigurationPlan(edits: merged, tool: plan.tool, profileID: plan.profileID)
            try privateWrite(JSONEncoder().encode(receipt), to: file)
        } else {
            try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
            try privateWrite(JSONEncoder().encode(receipt), to: file, exclusive: true)
        }
    }
    static func validateBinding(connection: StudioProfile, tool: StudioConfiguredTool, directory: URL) throws {
        try validateBinding(connection: connection, receipt: receiptURL(tool: tool, directory: directory))
    }
    static func validateBinding(connection: StudioProfile, receipt: URL) throws {
        guard let data = try read(receipt) else { return }
        let previous = try JSONDecoder().decode(StudioConfigurationPlan.self, from: data)
        guard bindingOwners(previous) == [connection.id] else { throw StudioConfigurationError.destinationInUse }
    }
    /// Disconnecting removes a slot but leaves its receipt, and a newly entered
    /// key gets a new slot ID. When every recorded owner is gone from Watch and
    /// the files still hold that import, `owner` takes the receipt over. The
    /// original `before` stays, so restore still returns to the state before
    /// Agent Watch. Receipts of a saved slot and unknown legacy receipts are
    /// never taken over. Returns whether ownership changed.
    @discardableResult
    public static func adoptOrphanedReceipt(_ file: URL, owner: String, savedProfiles: Set<String>) throws -> Bool {
        try checked(file)
        guard savedProfiles.contains(owner), let data = try read(file) else { return false }
        let old = try JSONDecoder().decode(StudioConfigurationPlan.self, from: data)
        let owners = bindingOwners(old)
        guard !owners.isEmpty, owners.isDisjoint(with: savedProfiles) else { return false }
        for edit in old.edits { guard try read(edit.file) == edit.after else { throw StudioConfigurationError.changed } }
        try privateWrite(JSONEncoder().encode(StudioConfigurationPlan(edits: old.edits, tool: old.tool, profileID: owner)), to: file)
        return true
    }
    /// Legacy receipts predate the explicit slot ID. Only recognize the exact
    /// generated helper argument; never adopt an unknown receipt silently.
    static func bindingOwners(_ plan: StudioConfigurationPlan) -> Set<String> {
        if let id = plan.profileID { return [id] }
        let expression = try! NSRegularExpression(pattern: #"--profile[\s\"'\\,\[\]]{1,20}([a-f0-9]{64})"#)
        return Set(plan.edits.flatMap { edit in
            let text = String(decoding: edit.after, as: UTF8.self) as NSString
            return expression.matches(in: text as String, range: NSRange(location: 0, length: text.length)).map { text.substring(with: $0.range(at: 1)) }
        })
    }
    public static func restoreReceipt(at file: URL) throws {
        guard let data = try read(file) else { throw StudioConfigurationError.invalid }
        let plan = try JSONDecoder().decode(StudioConfigurationPlan.self, from: data)
        try restore(plan)
        try FileManager.default.removeItem(at: file)
    }
    /// Persist the original before mutation; failed, fully rolled-back writes
    /// must not replace an earlier valid restore point.
    public static func apply(_ plan: StudioConfigurationPlan, receipt file: URL) throws {
        for edit in plan.edits { guard try read(edit.file) == edit.before else { throw StudioConfigurationError.changed } }
        let previous = try read(file)
        try saveReceipt(plan, to: file)
        do { try apply(plan) }
        catch {
            let rolledBack = plan.edits.allSatisfy { edit in
                do { return try read(edit.file) == edit.before } catch { return false }
            }
            if rolledBack {
                if let previous { try privateWrite(previous, to: file) }
                else { try FileManager.default.removeItem(at: file) }
            }
            throw error
        }
    }
    /// Recheck all files before mutation. Return a receipt for guarded rollback.
    public static func apply(_ plan: StudioConfigurationPlan) throws {
        for edit in plan.edits { guard try read(edit.file) == edit.before else { throw StudioConfigurationError.changed } }
        var written: [StudioConfigurationEdit] = []
        do {
            for edit in plan.edits {
                try checked(edit.file)
                try FileManager.default.createDirectory(at: edit.file.deletingLastPathComponent(), withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
                try privateWrite(edit.after, to: edit.file)
                written.append(edit)
            }
        } catch {
            try? restore(StudioConfigurationPlan(edits: written, tool: plan.tool)); throw error
        }
    }
    public static func restore(_ plan: StudioConfigurationPlan) throws {
        for edit in plan.edits { guard try read(edit.file) == edit.after else { throw StudioConfigurationError.changed } }
        for edit in plan.edits.reversed() {
            if let before = edit.before { try privateWrite(before, to: edit.file) }
            else { try FileManager.default.removeItem(at: edit.file) }
        }
    }
}
