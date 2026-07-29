// Sheet shown when the user clicks an event row in LiveActivityCard.
// Surfaces the full SessionEvent detail: status pills, timeline (toolUse),
// complete summary with text selection, and a scrollable result preview.

import SwiftUI
import ClaudeWatchCore

struct EventDetailView: View {
    let event: SessionEvent
    let onDismiss: () -> Void

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
                .background(Claude.border)
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    statusRow
                    if event.kind == .toolUse {
                        timeline
                    }
                    summaryCard
                    if let preview = event.resultPreview, !preview.isEmpty {
                        resultPreviewCard(preview)
                    }
                    footer
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
            iconBadge
            VStack(alignment: .leading, spacing: 2) {
                Text("Event")
                    .font(ClaudeFont.heading(18))
                    .foregroundStyle(Claude.textPrimary)
                Text(kindLabel)
                    .font(ClaudeFont.body(12))
                    .foregroundStyle(kindLabelColor)
            }
            Spacer()
            Button("Close", action: onDismiss)
                .keyboardShortcut(.cancelAction)
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 14)
        .background(Claude.surface)
    }

    private var iconBadge: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 9)
                .fill(roleColor.opacity(0.18))
            Image(systemName: iconName)
                .font(.system(size: 16, weight: .medium))
                .foregroundStyle(roleColor)
        }
        .frame(width: 36, height: 36)
    }

    // MARK: - Status row

    private var statusRow: some View {
        HStack(spacing: 16) {
            badge("STATUS",
                  value: statusLabel,
                  tint: statusTint)
            badge("DURATION",
                  value: durationText,
                  tint: Claude.textPrimary)
            badge("TOOL ID",
                  value: toolIdSuffix,
                  tint: Claude.textMuted,
                  mono: true)
        }
    }

    // MARK: - Timeline (toolUse only)

    private var timeline: some View {
        HStack(alignment: .top, spacing: 24) {
            timelineCell(label: "Spawned", iso: event.timestamp)
            Image(systemName: "arrow.right")
                .foregroundStyle(Claude.textMuted)
                .padding(.top, 18)
            timelineCell(label: "Completed", iso: event.completedAt ?? "—")
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

    // MARK: - Summary card

    private var summaryCard: some View {
        VStack(alignment: .leading, spacing: 8) {
            SectionLabel(text: "Summary")
            Text(event.summary.isEmpty ? "(no summary)" : event.summary)
                .font(summaryFont)
                .foregroundStyle(Claude.textPrimary)
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .claudeCard()
    }

    // MARK: - Result preview card

    private func resultPreviewCard(_ preview: String) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            SectionLabel(text: "Result (preview)")
            ScrollView {
                Text(preview)
                    .font(ClaudeFont.mono(11))
                    .foregroundStyle(Claude.textPrimary)
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .frame(maxHeight: 180)
        }
        .claudeCard()
    }

    // MARK: - Footer

    private var footer: some View {
        HStack {
            Text("Full event id: \(event.id)")
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

    private var iconName: String {
        switch event.kind {
        case .userMessage:       return "person.crop.circle.fill"
        case .assistantText:     return "sparkles"
        case .assistantThinking: return "brain"
        case .toolUse:           return ToolIcon.symbol(for: event.toolName ?? "")
        }
    }

    private var roleColor: Color {
        switch event.kind {
        case .userMessage:       return .pink
        case .assistantText:     return Claude.orange
        case .assistantThinking: return .purple
        case .toolUse:           return ToolIcon.tint(for: event.toolName ?? "")
        }
    }

    private var kindLabel: String {
        switch event.kind {
        case .userMessage:       return "User message"
        case .assistantText:     return "Assistant reply"
        case .assistantThinking: return "Thinking block"
        case .toolUse:
            if let name = event.toolName { return "Tool · \(name)" }
            return "Tool use"
        }
    }

    private var kindLabelColor: Color {
        event.kind == .toolUse
            ? (event.completed ? Claude.textMuted : Claude.live)
            : Claude.textMuted
    }

    private var statusLabel: String {
        switch event.kind {
        case .toolUse:  return event.completed ? "Done" : "Open"
        default:        return "—"
        }
    }

    private var statusTint: Color {
        switch event.kind {
        case .toolUse:  return event.completed ? Claude.textMuted : Claude.live
        default:        return Claude.textMuted
        }
    }

    private var toolIdSuffix: String {
        guard let uid = event.toolUseId, !uid.isEmpty else {
            return String(event.id.suffix(12))
        }
        return String(uid.suffix(12))
    }

    private var summaryFont: Font {
        switch event.kind {
        case .toolUse, .userMessage: return ClaudeFont.mono(12)
        default:                     return ClaudeFont.body(13)
        }
    }

    private var durationText: String {
        guard event.kind == .toolUse,
              let end = event.completedAt, !end.isEmpty,
              let s = parseISO(event.timestamp),
              let e = parseISO(end) else {
            if event.kind == .toolUse && !event.completed { return "running" }
            return "—"
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
