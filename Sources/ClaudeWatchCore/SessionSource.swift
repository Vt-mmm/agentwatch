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

import Foundation

public enum SessionSource: String, Sendable, CaseIterable {
    case cli
    case desktop
    /// v0.7.0: Codex CLI/Desktop — JSONL ở ~/.codex/sessions/YYYY/MM/DD/rollout-*.jsonl.
    case codex

    public var label: String {
        switch self {
        case .cli:     return "Claude CLI"
        case .desktop: return "Claude Desktop"
        case .codex:   return "Codex"
        }
    }

    public var shortLabel: String {
        switch self {
        case .cli:     return "CLI"
        case .desktop: return "Desk"
        case .codex:   return "Codex"
        }
    }

    public var emoji: String {
        switch self {
        case .cli:     return "⌨︎"
        case .desktop: return "🖥"
        case .codex:   return "🤖"
        }
    }

    /// Agent vendor — Anthropic (Claude) hay OpenAI (Codex). Hữu ích cho stats
    /// breakdown "Claude vs Codex" gộp CLI + Desktop về cùng vendor.
    public var vendor: AgentVendor {
        switch self {
        case .cli, .desktop: return .claude
        case .codex:         return .codex
        }
    }
}

/// Agent vendor — gộp source cùng vendor lại cho stats breakdown.
public enum AgentVendor: String, Sendable, CaseIterable {
    case claude
    case codex

    public var label: String {
        switch self {
        case .claude: return "Claude"
        case .codex:  return "Codex"
        }
    }
}
