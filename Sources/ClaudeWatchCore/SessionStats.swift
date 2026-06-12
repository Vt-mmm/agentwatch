// Aggregated stats for one Claude Code session (one JSONL transcript file).

import Foundation

public struct SessionStats: Sendable, Equatable {
    public let sessionId: String       // jsonl filename without extension
    public let projectSlug: String     // parent directory name under ~/.claude/projects
    public let filePath: URL

    public var model: String = ""
    public var startedAt: String = ""
    public var lastEventAt: String = ""

    public var messageCount: Int = 0
    public var inputTokens: Int = 0
    public var outputTokens: Int = 0
    public var cacheReadTokens: Int = 0
    public var cacheWriteTokens: Int = 0
    public var toolCalls: Int = 0
    public var agents: [AgentSpawn] = []
    /// Sliding window of the latest events (≤ `eventWindowSize`),
    /// chronological order (oldest first). 500 = đủ cho 1 phiên dài + paginate.
    public var events: [SessionEvent] = []
    public static let eventWindowSize = 500

    public init(sessionId: String, projectSlug: String, filePath: URL) {
        self.sessionId = sessionId
        self.projectSlug = projectSlug
        self.filePath = filePath
    }

    public var totalTokens: Int {
        inputTokens + outputTokens + cacheReadTokens + cacheWriteTokens
    }

    public var modelFamily: ModelFamily {
        ModelFamily.from(modelId: model)
    }

    public var cost: Double {
        Pricing.cost(
            family: modelFamily,
            inputTokens: inputTokens,
            outputTokens: outputTokens,
            cacheReadTokens: cacheReadTokens,
            cacheWriteTokens: cacheWriteTokens
        )
    }

    public var activeAgents: [AgentSpawn] {
        agents.filter { !$0.completed }
    }

    public var completedAgents: [AgentSpawn] {
        agents.filter { $0.completed }
    }

    public var mtime: Date {
        ProjectPath.mtime(of: filePath)
    }

    /// Latest event that's currently in progress — i.e. a tool_use without a
    /// matching tool_result. Returns nil when Claude is idle (no live tool).
    public var liveActivity: SessionEvent? {
        events.last(where: { $0.kind == .toolUse && !$0.completed })
    }
}
