// Per-subagent-type icon + tint. Falls back to a generic "person" when the
// type isn't recognised. Mirrors the agents documented in CLAUDE.md so
// common subagents get a meaningful glyph instead of all looking identical.

import SwiftUI

enum AgentIcon {

    /// SF Symbol name for a subagent type. Case-insensitive substring match.
    static func symbol(for subagentType: String) -> String {
        let t = subagentType.lowercased()
        if t.contains("explore") || t.contains("scout") || t.contains("search") {
            return "magnifyingglass.circle.fill"
        }
        if t.contains("review")    { return "checkmark.shield.fill" }
        if t.contains("plan")      { return "list.bullet.rectangle.fill" }
        if t.contains("research")  { return "books.vertical.fill" }
        if t.contains("test")      { return "checkmark.circle.fill" }
        if t.contains("debug")     { return "ant.fill" }
        if t.contains("docs")      { return "doc.text.fill" }
        if t.contains("ui") || t.contains("ux") || t.contains("design") {
            return "paintbrush.pointed.fill"
        }
        if t.contains("fullstack") || t.contains("developer") || t.contains("backend") || t.contains("frontend") {
            return "hammer.fill"
        }
        if t.contains("simplif")   { return "leaf.fill" }
        if t.contains("brainstorm") { return "lightbulb.fill" }
        if t.contains("git")       { return "arrow.triangle.branch" }
        if t.contains("journal")   { return "pencil.and.scribble" }
        if t.contains("project-manager") || t.contains("manager") {
            return "person.badge.clock.fill"
        }
        if t.contains("guide")     { return "book.closed.fill" }
        if t.contains("general")   { return "sparkle" }
        return "person.crop.circle.fill"
    }

    /// Brand-aligned tint per category.
    static func tint(for subagentType: String) -> Color {
        let t = subagentType.lowercased()
        if t.contains("review") || t.contains("test")       { return Claude.live }
        if t.contains("debug")                              { return .red }
        if t.contains("plan")  || t.contains("research")    { return .blue }
        if t.contains("ui") || t.contains("ux") || t.contains("design") {
            return .purple
        }
        if t.contains("simplif") || t.contains("docs")      { return Claude.orange }
        if t.contains("explore") || t.contains("scout")     { return .indigo }
        return Claude.textMuted
    }
}
