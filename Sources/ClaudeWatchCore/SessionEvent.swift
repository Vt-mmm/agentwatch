// One human-readable event extracted from the JSONL transcript — user msg,
// assistant text, thinking, or tool_use. Tool_result lines are NOT separate
// events; they update the matching toolUse's `completed` + `resultPreview`.

import Foundation

public enum SessionEventKind: String, Sendable {
    case userMessage         // user typed something
    case assistantText       // Claude wrote a reply
    case assistantThinking   // a `thinking` content block on an assistant msg
    case toolUse             // Claude invoked a tool
}

public struct SessionEvent: Identifiable, Sendable, Equatable {
    public let id: String           // tool_use id if available, else timestamp+index
    public let timestamp: String
    public let kind: SessionEventKind
    public let toolName: String?    // only for kind == .toolUse
    public let toolUseId: String?
    public let summary: String
    public var completed: Bool      // toolUse only
    public var completedAt: String?
    public var resultPreview: String?
    /// Khi tool_result chứa image block (vd mcp screenshot) — capture base64
    /// + mime type để render inline. Capped 5MB base64 (~3.7MB actual image).
    public var imageBase64: String?
    public var imageMimeType: String?
    /// Khi tool_result content là URL ảnh thay vì base64.
    public var imageURL: String?

    public init(id: String, timestamp: String, kind: SessionEventKind,
                toolName: String? = nil, toolUseId: String? = nil,
                summary: String, completed: Bool = false,
                completedAt: String? = nil, resultPreview: String? = nil,
                imageBase64: String? = nil, imageMimeType: String? = nil,
                imageURL: String? = nil) {
        self.id = id
        self.timestamp = timestamp
        self.kind = kind
        self.toolName = toolName
        self.toolUseId = toolUseId
        self.summary = summary
        self.completed = completed
        self.completedAt = completedAt
        self.resultPreview = resultPreview
        self.imageBase64 = imageBase64
        self.imageMimeType = imageMimeType
        self.imageURL = imageURL
    }
}
