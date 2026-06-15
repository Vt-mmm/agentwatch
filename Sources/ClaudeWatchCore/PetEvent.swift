// PetEvent — newline-delimited JSON protocol qua Unix socket.
// CLI hook gửi event → app socket server nhận → cập nhật FloatingPetController.
//
// Socket path: ~/Library/Application Support/ClaudeWatch/pet.sock
// Protocol: một JSON object mỗi dòng (newline-delimited JSON).

import Foundation

/// Event gửi từ CLI hook tới app qua Unix domain socket.
public struct PetEvent: Codable, Sendable {
    /// Loại event. Khớp với event name trong Claude Code hooks.
    public enum Kind: String, Codable, Sendable {
        case sessionStart    = "session-start"
        case stop            = "stop"
        case preCompact      = "pre-compact"
        case userPrompt      = "user-prompt"
        case postToolUse     = "post-tool-use"
        case subagentStop    = "subagent-stop"
    }

    public let kind: Kind
    public let sessionId: String?
    public let transcriptPath: String?
    public let toolName: String?
    public let timestamp: Date

    public init(kind: Kind,
                sessionId: String? = nil,
                transcriptPath: String? = nil,
                toolName: String? = nil,
                timestamp: Date = Date()) {
        self.kind = kind
        self.sessionId = sessionId
        self.transcriptPath = transcriptPath
        self.toolName = toolName
        self.timestamp = timestamp
    }

    // MARK: - Socket path

    /// Path tới Unix domain socket. Tạo parent dir nếu chưa có.
    public static var socketPath: String {
        let appSupport = FileManager.default
            .urls(for: .applicationSupportDirectory, in: .userDomainMask)
            .first?
            .appendingPathComponent("ClaudeWatch")
            .path
            ?? (FileManager.default.homeDirectoryForCurrentUser
                .appendingPathComponent("Library/Application Support/ClaudeWatch").path)
        // Ensure dir exists (idempotent).
        try? FileManager.default.createDirectory(
            atPath: appSupport,
            withIntermediateDirectories: true,
            attributes: nil)
        return appSupport + "/pet.sock"
    }

    // MARK: - JSON coding

    /// Encoder dùng ISO8601 với fractional seconds để timestamp đủ precision.
    public static let jsonEncoder: JSONEncoder = {
        let enc = JSONEncoder()
        enc.dateEncodingStrategy = .iso8601
        return enc
    }()

    public static let jsonDecoder: JSONDecoder = {
        let dec = JSONDecoder()
        dec.dateDecodingStrategy = .iso8601
        return dec
    }()

    /// Serialize thành newline-terminated JSON bytes.
    public func toLine() throws -> Data {
        var data = try Self.jsonEncoder.encode(self)
        data.append(0x0A) // '\n'
        return data
    }
}
