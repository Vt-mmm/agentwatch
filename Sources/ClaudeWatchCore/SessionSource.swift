// Phân biệt nguồn session để app hiển thị badge + filter.
//
// CLI: ~/.claude/projects/<slug>/<uuid>.jsonl
//   - Terminal `claude` command
//   - Format: JSONL với content blocks array
//
// Desktop: ~/Library/Application Support/Claude/local-agent-mode-sessions/...
//   - Claude Desktop "Computer Use" / Local Agent Mode
//   - Format: JSONL audit log, `client_platform:"desktop_app"`, có `_audit_hmac`
//   - File tên audit.jsonl, nằm trong nested folder organization
//
// Codex: ~/.codex/sessions/YYYY/MM/DD/rollout-*.jsonl
//   - Codex CLI/Desktop rollout log
//
// PiAgent: ~/.pi/agent/sessions/**/*.jsonl
//   - Pi agent local session log, gồm cả subagent runs

import Foundation

public enum SessionSource: String, Sendable, CaseIterable {
    case cli
    case desktop
    /// v0.7.0: Codex CLI/Desktop — JSONL ở ~/.codex/sessions/YYYY/MM/DD/rollout-*.jsonl.
    case codex
    /// v0.9.0: PiAgent local sessions — JSONL ở ~/.pi/agent/sessions/**.
    case piagent

    public var label: String {
        switch self {
        case .cli:     return "Claude CLI"
        case .desktop: return "Claude Desktop"
        case .codex:   return "Codex"
        case .piagent: return "PiAgent"
        }
    }

    public var shortLabel: String {
        switch self {
        case .cli:     return "CLI"
        case .desktop: return "Desk"
        case .codex:   return "Codex"
        case .piagent: return "Pi"
        }
    }

    public var emoji: String {
        switch self {
        case .cli:     return "⌨︎"
        case .desktop: return "🖥"
        case .codex:   return "🤖"
        case .piagent: return "π"
        }
    }

    /// Agent vendor — Anthropic/OpenAI/PiAgent. Hữu ích cho stats breakdown.
    public var vendor: AgentVendor {
        switch self {
        case .cli, .desktop: return .claude
        case .codex:         return .codex
        case .piagent:       return .piagent
        }
    }
}

/// Agent vendor — gộp source cùng vendor lại cho stats breakdown.
public enum AgentVendor: String, Sendable, CaseIterable {
    case claude
    case codex
    case piagent

    public var label: String {
        switch self {
        case .claude: return "Claude"
        case .codex: return "Codex"
        case .piagent: return "PiAgent"
        }
    }
}
