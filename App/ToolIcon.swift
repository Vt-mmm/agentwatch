// SF Symbol + tint for each tool name used by Claude Code. Falls back to a
// generic wrench when the name is unknown.

import SwiftUI

enum ToolIcon {

    static func symbol(for toolName: String) -> String {
        switch toolName {
        case "Bash":             return "terminal"
        case "Read":             return "doc.text"
        case "Write":            return "square.and.pencil"
        case "Edit", "MultiEdit": return "pencil.line"
        case "NotebookEdit":     return "book"
        case "Glob":             return "doc.on.doc"
        case "Grep":             return "magnifyingglass"
        case "Agent":            return "person.2.crop.square.stack"
        case "WebFetch":         return "arrow.down.circle"
        case "WebSearch":        return "globe"
        case "AskUserQuestion":  return "questionmark.bubble"
        case "TodoWrite", "TaskCreate", "TaskUpdate":
            return "checklist"
        case "ToolSearch":       return "sparkle.magnifyingglass"
        case "ScheduleWakeup":   return "alarm"
        case "ExitPlanMode", "EnterPlanMode":
            return "rectangle.and.text.magnifyingglass"
        default:                 return "wrench.adjustable"
        }
    }

    static func tint(for toolName: String) -> Color {
        switch toolName {
        case "Bash":                     return .green
        case "Read", "Glob", "Grep":     return .blue
        case "Write", "Edit", "MultiEdit", "NotebookEdit":
            return Claude.orange
        case "Agent":                    return .purple
        case "WebFetch", "WebSearch":    return .cyan
        case "AskUserQuestion":          return .pink
        case "TodoWrite", "TaskCreate", "TaskUpdate":
            return .indigo
        default:                         return Claude.textMuted
        }
    }
}
