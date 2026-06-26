// Compact menu bar dropdown. Same theme tokens as the full window.

import SwiftUI
import ClaudeWatchCore

struct MenuBarSummaryView: View {
    @Environment(SessionWatcher.self) private var watcher
    @Environment(ProjectStore.self) private var projectStore
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            header
            Divider().background(Claude.border)
            if let s = watcher.stats {
                statsBlock(s)
                Divider().background(Claude.border)
                agentBlock(s)
            } else {
                Text(emptyMessage)
                    .font(ClaudeFont.body(12))
                    .foregroundStyle(Claude.textMuted)
            }
            Divider().background(Claude.border)
            footer
        }
        .padding(14)
        .frame(width: 320)
        .background(Claude.background)
    }

    private var header: some View {
        HStack(spacing: 10) {
            ZStack {
                Circle().fill(Claude.orangeSoft).frame(width: 30, height: 30)
                Image(systemName: "sparkles")
                    .font(.system(size: 13))
                    .foregroundStyle(Claude.orange)
            }
            VStack(alignment: .leading, spacing: 1) {
                Text("Agent Watch")
                    .font(ClaudeFont.heading(14))
                    .foregroundStyle(Claude.textPrimary)
                Text(subtitle)
                .font(ClaudeFont.mono(10))
                .foregroundStyle(Claude.textMuted)
                .lineLimit(1)
                .truncationMode(.middle)
            }
        }
    }

    private func statsBlock(_ s: SessionStats) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            row("Model",     s.modelFamily.rawValue, color: Claude.orange)
            row("Input",     TokenFormatter.compact(s.inputTokens))
            row("Output",    TokenFormatter.compact(s.outputTokens))
            row("Cache R",   TokenFormatter.compact(s.cacheReadTokens))
            row("Cache W",   TokenFormatter.compact(s.cacheWriteTokens))
            row("Cost",      TokenFormatter.usd(s.cost), color: Claude.orange, bold: true)
            row("Messages",  "\(s.messageCount)")
        }
    }

    private func agentBlock(_ s: SessionStats) -> some View {
        HStack(spacing: 8) {
            Circle()
                .fill(s.activeAgents.isEmpty ? Claude.done : Claude.live)
                .frame(width: 8, height: 8)
            Text("\(s.activeAgents.count) live · \(s.agents.count) total agents")
                .font(ClaudeFont.body(12))
                .foregroundStyle(Claude.textPrimary)
        }
    }

    private var footer: some View {
        HStack {
            Button("Open window") { openWindow(id: "main") }
                .buttonStyle(.plain)
                .font(ClaudeFont.body(12))
                .foregroundStyle(Claude.orange)
            Spacer()
            Button("Quit") { NSApp.terminate(nil) }
                .buttonStyle(.plain)
                .font(ClaudeFont.body(12))
                .foregroundStyle(Claude.textMuted)
        }
    }

    private var subtitle: String {
        if projectStore.followLatest {
            return watcher.resolvedFolder?.lastPathComponent ?? "Following active…"
        }
        return projectStore.pinnedFolder?.lastPathComponent ?? "No folder pinned"
    }

    private var emptyMessage: String {
        if projectStore.followLatest {
            return "Scanning for active session…"
        }
        return projectStore.pinnedFolder == nil
            ? "Pin a folder to start."
            : "Waiting for session activity…"
    }

    private func row(_ label: String, _ value: String,
                     color: Color = Claude.textPrimary,
                     bold: Bool = false) -> some View {
        HStack {
            Text(label)
                .foregroundStyle(Claude.textMuted)
                .font(ClaudeFont.body(12))
            Spacer()
            Text(value)
                .font(bold ? ClaudeFont.mono(13, weight: .semibold)
                           : ClaudeFont.mono(12))
                .foregroundStyle(color)
        }
    }
}
