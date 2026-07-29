// Compact menu bar dropdown. Same theme tokens as the full window.

import SwiftUI
import ClaudeWatchCore

struct MenuBarSummaryView: View {
    @Environment(SessionWatcher.self) private var watcher
    @Environment(ProjectStore.self) private var projectStore
    @Environment(CodexLivePoller.self) private var codex
    @Environment(PiAgentLivePoller.self) private var piAgent
    @Environment(\.openWindow) private var openWindow

    private var hasAnyLiveAgent: Bool {
        watcher.stats != nil || codex.snapshot.sessionCount > 0 || piAgent.snapshot.sessionCount > 0
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            header
            Divider().background(Claude.border)
            if hasAnyLiveAgent {
                liveTotalsBlock
                if let s = watcher.stats {
                    Divider().background(Claude.border)
                    statsBlock(s)
                }
                Divider().background(Claude.border)
                agentBlock(watcher.stats)
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
            if let thinking = s.thinkingLevel {
                row("Thinking", thinking, color: .purple)
            }
            row("Input",     TokenFormatter.compact(s.inputTokens))
            row("Output",    TokenFormatter.compact(s.outputTokens))
            if s.reasoningTokens > 0 {
                row("Reason", TokenFormatter.compact(s.reasoningTokens))
            }
            row("Cache R",   TokenFormatter.compact(s.cacheReadTokens))
            row("Cache W",   TokenFormatter.compact(s.cacheWriteTokens))
            row("Cost",      TokenFormatter.usd(s.cost), color: Claude.orange, bold: true)
            row("Messages",  "\(s.messageCount)")
        }
    }

    private var liveTotalsBlock: some View {
        let claude = watcher.stats
        let codexSnapshot = codex.snapshot
        let piSnapshot = piAgent.snapshot
        let sessions = (claude == nil ? 0 : 1) + codexSnapshot.sessionCount + piSnapshot.sessionCount
        let tokens = (claude?.totalTokens ?? 0) + codexSnapshot.totalTokens + piSnapshot.totalTokens
        let cost = (claude?.cost ?? 0) + codexSnapshot.totalCost + piSnapshot.totalCost
        return VStack(alignment: .leading, spacing: 5) {
            row("Live", "\(sessions) sessions", color: sessions > 0 ? Claude.live : Claude.textMuted)
            row("Total", TokenFormatter.compact(tokens) + " tok")
            row("Cost", TokenFormatter.usd(cost), color: Claude.orange, bold: true)
            if codexSnapshot.sessionCount > 0 {
                row("Codex", "\(codexSnapshot.sessionCount) · \(TokenFormatter.compact(codexSnapshot.totalTokens)) tok", color: .green)
            }
            if piSnapshot.sessionCount > 0 {
                row("PiAgent", "\(piSnapshot.namedTaskCount)/\(piSnapshot.sessionCount) named · \(TokenFormatter.compact(piSnapshot.totalTokens)) tok", color: .purple)
            }
        }
    }

    private func agentBlock(_ s: SessionStats?) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            if let s {
                HStack(spacing: 8) {
                    Circle()
                        .fill(s.activeAgents.isEmpty ? Claude.done : Claude.live)
                        .frame(width: 8, height: 8)
                    Text("\(s.activeAgents.count) live · \(s.agents.count) total Claude agents")
                        .font(ClaudeFont.body(12))
                        .foregroundStyle(Claude.textPrimary)
                }
            }
            if let latest = piAgent.snapshot.latestSession {
                row("Pi task", latest.displayTitle, color: latest.hasTaskSessionTitle ? Claude.textPrimary : .orange)
            }
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
                .lineLimit(1)
                .truncationMode(.middle)
        }
    }
}
