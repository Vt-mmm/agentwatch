import Foundation

/// API-key vendors (DeepSeek, Kimi, GLM, MiMo, Qwen, OpenCode, Grok) Studio
/// runs over OpenAI Chat Completions. Studio names them; Agent Watch only
/// checks the shape and passes their models and run grants to Piagent.
public enum StudioVendor {
    /// Sent to Studio so it may list vendor models; older builds are not sent them.
    public static let clientFeatures = "api-vendors"

    public static func valid(_ id: String) -> Bool {
        guard id != "claude", id != "codex", (2...40).contains(id.utf8.count), let first = id.utf8.first, (97...122).contains(first) else { return false }
        return id.utf8.allSatisfy { (97...122).contains($0) || (48...57).contains($0) || $0 == 45 }
    }

    public static func validModel(ownedBy: String, nativeProtocol: String) -> Bool {
        (ownedBy == "claude" && nativeProtocol == "messages") || (ownedBy == "codex" && nativeProtocol == "responses") || (valid(ownedBy) && nativeProtocol == "chat")
    }
}
