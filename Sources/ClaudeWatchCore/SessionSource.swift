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

    public var label: String {
        switch self {
        case .cli:     return "CLI"
        case .desktop: return "Desktop"
        }
    }

    public var emoji: String {
        switch self {
        case .cli:     return "⌨︎"
        case .desktop: return "🖥"
        }
    }
}
