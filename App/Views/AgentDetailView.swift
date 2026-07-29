// Sheet shown when the user clicks an agent row. Surfaces everything captured
// for one Agent tool_use: type, full description + prompt, status, timestamps,
// duration, and the first 600 chars of the tool_result content.

import SwiftUI
import ClaudeWatchCore

struct AgentDetailView: View {
    let agent: AgentSpawn
    let onDismiss: () -> Void

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
                .background(Claude.border)
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    statusRow
                    timeline
                    section("Description", body: agent.description.isEmpty
                            ? "(no description)" : agent.description, mono: false)
                    if !agent.prompt.isEmpty {
                        section("Prompt", body: agent.prompt, mono: true)
                    }
                    if let snippet = agent.resultSnippet, !snippet.isEmpty {
                        section("Result (first 600 chars)", body: snippet, mono: true)
                    }
                    metaRow
                }
                .padding(20)
            }
        }
        .frame(width: 580, height: 540)
        .background(Claude.background)
    }

    // MARK: - Header

    private var header: some View {
        HStack(spacing: 12) {
            statusDot
            VStack(alignment: .leading, spacing: 2) {
                Text(agent.subagentType)
                    .font(ClaudeFont.heading(18))
                    .foregroundStyle(Claude.textPrimary)
                Text(agent.completed ? "Completed" : "Open")
                    .font(ClaudeFont.body(12))
                    .foregroundStyle(agent.completed ? Claude.textMuted : Claude.live)
            }
            Spacer()
            Button("Close", action: onDismiss)
                .keyboardShortcut(.cancelAction)
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 14)
        .background(Claude.surface)
    }

    private var statusDot: some View {
        Circle()
            .fill(agent.completed ? Claude.done : Claude.live)
            .frame(width: 12, height: 12)
            .overlay(
                Circle().strokeBorder(Claude.border, lineWidth: 0.5)
            )
    }

    // MARK: - Status / timeline

    private var statusRow: some View {
        HStack(spacing: 16) {
            badge("STATUS",
                  value: agent.completed ? "Done" : "Open",
                  tint: agent.completed ? Claude.textMuted : Claude.live)
            badge("DURATION", value: durationText, tint: Claude.textPrimary)
            badge("TOOL ID",
                  value: String(agent.id.suffix(12)),
                  tint: Claude.textMuted, mono: true)
        }
    }

    private var timeline: some View {
        HStack(alignment: .top, spacing: 24) {
            timelineCell(label: "Spawned", iso: agent.timestamp)
            Image(systemName: "arrow.right")
                .foregroundStyle(Claude.textMuted)
                .padding(.top, 18)
            timelineCell(label: "Completed", iso: agent.completedAt ?? "—")
        }
        .claudeCard()
    }

    private func timelineCell(label: String, iso: String) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            SectionLabel(text: label)
            Text(TokenFormatter.clockTime(from: iso))
                .font(ClaudeFont.mono(15, weight: .medium))
                .foregroundStyle(Claude.textPrimary)
            Text(iso == "—" ? "" : iso)
                .font(ClaudeFont.mono(10))
                .foregroundStyle(Claude.textMuted)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    // MARK: - Sections

    private func section(_ title: String, body: String, mono: Bool) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            SectionLabel(text: title)
            Text(body)
                .font(mono ? ClaudeFont.mono(12) : ClaudeFont.body(13))
                .foregroundStyle(Claude.textPrimary)
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .claudeCard()
    }

    private var metaRow: some View {
        HStack {
            Text("Full tool_use_id: \(agent.id)")
                .font(ClaudeFont.mono(10))
                .foregroundStyle(Claude.textMuted)
                .textSelection(.enabled)
            Spacer()
        }
    }

    // MARK: - Helpers

    private func badge(_ label: String, value: String,
                       tint: Color, mono: Bool = false) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            SectionLabel(text: label)
            Text(value)
                .font(mono ? ClaudeFont.mono(13) : ClaudeFont.body(13))
                .foregroundStyle(tint)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .claudeCard(padding: 12)
    }

    private var durationText: String {
        guard let end = agent.completedAt, !end.isEmpty,
              let s = parseISO(agent.timestamp),
              let e = parseISO(end) else {
            return agent.completed ? "?" : "running"
        }
        let secs = max(0, Int(e.timeIntervalSince(s)))
        if secs >= 60 { return "\(secs / 60)m \(secs % 60)s" }
        return "\(secs)s"
    }

    private func parseISO(_ s: String) -> Date? {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let d = f.date(from: s) { return d }
        f.formatOptions = [.withInternetDateTime]
        return f.date(from: s)
    }
}
