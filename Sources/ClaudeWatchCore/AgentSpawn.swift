// One `Agent` tool_use block from an assistant message — i.e. a subagent spawn.

import Foundation

public struct AgentSpawn: Identifiable, Sendable, Equatable {
    public let id: String              // tool_use_id from the JSONL block
    public let subagentType: String    // e.g. "Explore", "code-reviewer"
    public let description: String     // full description from input.description
    public let prompt: String          // input.prompt (often long — full task spec)
    public let timestamp: String       // ISO8601 of the spawn event
    public var completed: Bool         // flips true when matching tool_result seen
    public var completedAt: String?    // ISO8601 of the matching tool_result, if any
    public var resultSnippet: String?  // first ~600 chars of tool_result content

    public init(id: String, subagentType: String, description: String,
                prompt: String = "",
                timestamp: String, completed: Bool = false,
                completedAt: String? = nil, resultSnippet: String? = nil) {
        self.id = id
        self.subagentType = subagentType
        self.description = description
        self.prompt = prompt
        self.timestamp = timestamp
        self.completed = completed
        self.completedAt = completedAt
        self.resultSnippet = resultSnippet
    }
}
