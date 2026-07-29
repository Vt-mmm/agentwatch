// Compact menu bar dropdown. Same theme tokens as the full window.

import SwiftUI
import ClaudeWatchCore

struct MenuBarSummaryView: View {
    @Environment(SessionWatcher.self) private var watcher
    @Environment(ProjectStore.self) private var projectStore
    @Environment(CodexLivePoller.self) private var codex
    @Environment(PiAgentLivePoller.self) private var piAgent
    @Environment(SupervisorLockStore.self) private var supervisorLock
    @Environment(\.openWindow) private var openWindow

    private var hasAnySnapshot: Bool {
        watcher.stats != nil || codex.snapshot.sessionCount > 0 || piAgent.snapshot.sessionCount > 0
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            header
            Divider().background(Claude.border)
            lockBlock
            Divider().background(Claude.border)
            if hasAnySnapshot {
                liveTotalsBlock
                if let detail = latestDetail {
                    Divider().background(Claude.border)
                    statsBlock(detail)
                }
                Divider().background(Claude.border)
                agentBlock()
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

    private func statsBlock(_ detail: MenuLiveDetail) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            row("Latest", detail.title, color: detail.sourceColor)
            row("Source", detail.source)
            row("Model", detail.model, color: detail.sourceColor)
            if let thinking = detail.thinkingLevel {
                row("Thinking", thinking, color: .purple)
            }
            row("Input", TokenFormatter.compact(detail.inputTokens))
            row("Output", TokenFormatter.compact(detail.outputTokens))
            if detail.reasoningTokens > 0 {
                row("Reason", TokenFormatter.compact(detail.reasoningTokens))
            }
            row("Cache R", TokenFormatter.compact(detail.cacheReadTokens))
            row("Cache W", TokenFormatter.compact(detail.cacheWriteTokens))
            row("Cost", TokenFormatter.usd(detail.cost), color: detail.sourceColor, bold: true)
            row("Prompts", "\(detail.promptCount)")
            row("Tools", "\(detail.toolCount)")
        }
    }

    private var liveTotalsBlock: some View {
        let claude = watcher.stats
        let codexSnapshot = codex.snapshot
        let piSnapshot = piAgent.snapshot
        let sessions = (claude == nil ? 0 : 1) + codexSnapshot.sessionCount + piSnapshot.sessionCount
        let tokens = (claude?.totalTokens ?? 0) + codexSnapshot.totalTokens + piSnapshot.totalTokens
        let reasoning = (claude?.reasoningTokens ?? 0)
            + codexSnapshot.totalReasoningTokens
            + piSnapshot.totalReasoningTokens
        let cost = (claude?.cost ?? 0) + codexSnapshot.totalCost + piSnapshot.totalCost
        let thinking = thinkingBreakdown()
        return VStack(alignment: .leading, spacing: 5) {
            row("Snapshot", "\(sessions) sessions", color: sessions > 0 ? Claude.live : Claude.textMuted)
            row("Total", TokenFormatter.compact(tokens) + " tok")
            if reasoning > 0 {
                row("Reason", TokenFormatter.compact(reasoning) + " tok", color: .purple)
            }
            if !thinking.isEmpty {
                row("Thinking", thinking, color: .purple)
            }
            row("Cost", TokenFormatter.usd(cost), color: Claude.orange, bold: true)
            if codexSnapshot.sessionCount > 0 {
                row("Codex", "\(codexSnapshot.sessionCount) · \(TokenFormatter.compact(codexSnapshot.totalTokens)) tok", color: .green)
            }
            if piSnapshot.sessionCount > 0 {
                row("PiAgent", "\(piSnapshot.namedTaskCount)/\(piSnapshot.sessionCount) named · \(TokenFormatter.compact(piSnapshot.totalTokens)) tok", color: .purple)
            }
        }
    }

    private func agentBlock() -> some View {
        VStack(alignment: .leading, spacing: 6) {
            if let s = watcher.stats {
                HStack(spacing: 8) {
                    Circle()
                        .fill(s.activeAgents.isEmpty ? Claude.done : Claude.live)
                        .frame(width: 8, height: 8)
                    Text("\(s.activeAgents.count) open · \(s.agents.count) total Claude agents")
                        .font(ClaudeFont.body(12))
                        .foregroundStyle(Claude.textPrimary)
                }
            }
            if let latest = codex.snapshot.latestSession {
                row("Codex task", latest.displayTitle, color: .green)
            }
            if let latest = piAgent.snapshot.latestSession {
                row("Pi task", latest.displayTitle, color: latest.hasTaskSessionTitle ? Claude.textPrimary : .orange)
                if let thinking = latest.thinkingLevel {
                    row("Pi think", thinking, color: .purple)
                }
            }
        }
    }

    private var lockBlock: some View {
        HStack(spacing: 8) {
            Circle()
                .fill(supervisorLock.isLocked ? Claude.orange : Claude.done)
                .frame(width: 8, height: 8)
            VStack(alignment: .leading, spacing: 1) {
                Text(supervisorLock.isLocked ? "Supervisor lock on" : "Enrollment required")
                    .font(ClaudeFont.body(12))
                    .foregroundStyle(Claude.textPrimary)
                Text(supervisorLock.lockedByLabel ?? "Open window to enroll this machine")
                    .font(ClaudeFont.mono(10))
                    .foregroundStyle(Claude.textMuted)
            }
            Spacer()
        }
    }

    private var footer: some View {
        HStack {
            Button("Refresh") { refreshAuditSnapshots() }
                .buttonStyle(.plain)
                .font(ClaudeFont.body(12))
                .foregroundStyle(Claude.orange)
            Spacer()
            Button("Open window") { openWindow(id: "main") }
                .buttonStyle(.plain)
                .font(ClaudeFont.body(12))
                .foregroundStyle(Claude.orange)
            Spacer()
            Button("Quit…") {
                supervisorLock.requestQuit(source: "menu bar")
            }
                .buttonStyle(.plain)
                .font(ClaudeFont.body(12))
                .foregroundStyle(Claude.textMuted)
        }
    }

    private var subtitle: String {
        if projectStore.followLatest {
            return watcher.resolvedFolder?.lastPathComponent ?? "Latest snapshot"
        }
        return projectStore.pinnedFolder?.lastPathComponent ?? "No folder pinned"
    }

    private var emptyMessage: String {
        if projectStore.followLatest {
            return "No snapshot loaded. Press Refresh."
        }
        return projectStore.pinnedFolder == nil
            ? "Pin a folder to start."
            : "No session snapshot yet. Press Refresh."
    }

    private func refreshAuditSnapshots() {
        if projectStore.followLatest || projectStore.pinnedFolder == nil {
            watcher.loadLatest()
        } else if let folder = projectStore.pinnedFolder {
            watcher.loadPinned(folder: folder)
        }
        codex.refreshOnce()
        piAgent.refreshOnce()
    }

    private var latestDetail: MenuLiveDetail? {
        let claudeDetail = watcher.stats.map { s in
            MenuLiveDetail(
                source: "Claude",
                title: ProjectPath.displayPath(for: s.projectSlug),
                model: s.modelFamily.rawValue,
                thinkingLevel: s.thinkingLevel,
                inputTokens: s.inputTokens,
                outputTokens: s.outputTokens,
                reasoningTokens: s.reasoningTokens,
                cacheReadTokens: s.cacheReadTokens,
                cacheWriteTokens: s.cacheWriteTokens,
                cost: s.cost,
                promptCount: s.messageCount,
                toolCount: s.toolCalls,
                lastActivity: s.mtime,
                sourceColor: Claude.orange
            )
        }
        let codexDetail = codex.snapshot.latestSession.map { MenuLiveDetail(session: $0, sourceColor: .green) }
        let piDetail = piAgent.snapshot.latestSession.map { MenuLiveDetail(session: $0, sourceColor: .purple) }
        return [claudeDetail, codexDetail, piDetail]
            .compactMap { $0 }
            .sorted { $0.lastActivity > $1.lastActivity }
            .first
    }

    private func thinkingBreakdown() -> String {
        var levels: [String] = []
        if let level = watcher.stats?.thinkingLevel { levels.append(level) }
        levels.append(contentsOf: codex.snapshot.sessions.compactMap(\.thinkingLevel))
        levels.append(contentsOf: piAgent.snapshot.sessions.compactMap(\.thinkingLevel))
        return compactBreakdown(levels)
    }

    private func compactBreakdown(_ values: [String]) -> String {
        var counts: [String: Int] = [:]
        for value in values {
            let cleaned = value.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !cleaned.isEmpty else { continue }
            counts[cleaned, default: 0] += 1
        }
        let ranked = counts.sorted {
            if $0.value != $1.value { return $0.value > $1.value }
            return $0.key < $1.key
        }
        return ranked.prefix(2)
            .map { $0.value > 1 ? "\($0.key) x\($0.value)" : $0.key }
            .joined(separator: ", ")
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

private struct MenuLiveDetail {
    let source: String
    let title: String
    let model: String
    let thinkingLevel: String?
    let inputTokens: Int
    let outputTokens: Int
    let reasoningTokens: Int
    let cacheReadTokens: Int
    let cacheWriteTokens: Int
    let cost: Double
    let promptCount: Int
    let toolCount: Int
    let lastActivity: Date
    let sourceColor: Color

    init(source: String,
         title: String,
         model: String,
         thinkingLevel: String?,
         inputTokens: Int,
         outputTokens: Int,
         reasoningTokens: Int,
         cacheReadTokens: Int,
         cacheWriteTokens: Int,
         cost: Double,
         promptCount: Int,
         toolCount: Int,
         lastActivity: Date,
         sourceColor: Color) {
        self.source = source
        self.title = title
        self.model = model.isEmpty ? "unknown" : model
        self.thinkingLevel = thinkingLevel
        self.inputTokens = inputTokens
        self.outputTokens = outputTokens
        self.reasoningTokens = reasoningTokens
        self.cacheReadTokens = cacheReadTokens
        self.cacheWriteTokens = cacheWriteTokens
        self.cost = cost
        self.promptCount = promptCount
        self.toolCount = toolCount
        self.lastActivity = lastActivity
        self.sourceColor = sourceColor
    }

    init(session: SessionSummary, sourceColor: Color) {
        self.init(
            source: session.source.label,
            title: session.displayTitle,
            model: session.model,
            thinkingLevel: session.thinkingLevel,
            inputTokens: session.inputTokens,
            outputTokens: session.outputTokens,
            reasoningTokens: session.reasoningTokens,
            cacheReadTokens: session.cacheReadTokens,
            cacheWriteTokens: session.cacheWriteTokens,
            cost: session.cost,
            promptCount: session.promptCount,
            toolCount: session.toolCallCount,
            lastActivity: session.lastTimestamp ?? session.firstTimestamp ?? .distantPast,
            sourceColor: sourceColor
        )
    }
}
