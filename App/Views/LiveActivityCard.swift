// Reverse-chronological feed of session events from the latest loaded snapshot:
// user prompts, assistant replies, thinking, and tool invocations.

import SwiftUI
import ClaudeWatchCore

struct LiveActivityCard: View {
    let stats: SessionStats
    @State private var selected: SessionEvent?
    @State private var page: Int = 0
    private let pageSize = 15

    /// Events đảo ngược (mới nhất lên đầu) để paginate. Trang 1 luôn là newest.
    private var orderedEvents: [SessionEvent] {
        Array(stats.events.reversed())
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            header
            if let activity = stats.liveActivity {
                nowBanner(activity)
            }
            if stats.events.isEmpty {
                Text("No events in this session snapshot yet.")
                    .foregroundStyle(Claude.textMuted)
                    .font(ClaudeFont.body(12))
                    .padding(.vertical, 8)
            } else {
                feed
            }
        }
        .claudeCard()
        .sheet(item: $selected) { evt in
            EventDetailView(event: evt) { selected = nil }
        }
    }

    private var header: some View {
        let info = Pagination.info(items: orderedEvents, page: page, pageSize: pageSize)
        return HStack(spacing: 8) {
            Image(systemName: "waveform")
                .foregroundStyle(Claude.orange)
            Text("Session events")
                .font(ClaudeFont.heading())
                .foregroundStyle(Claude.textPrimary)
            Spacer()
            Text("\(stats.events.count) events")
                .font(ClaudeFont.label(11))
                .foregroundStyle(Claude.textMuted)
            Paginator(page: info.page, totalPages: info.totalPages) { page = $0 }
        }
    }

    private func nowBanner(_ activity: SessionEvent) -> some View {
        HStack(spacing: 10) {
            ZStack {
                Circle().fill(Claude.live.opacity(0.18)).frame(width: 28, height: 28)
                Circle().fill(Claude.live).frame(width: 8, height: 8)
            }
            VStack(alignment: .leading, spacing: 1) {
                HStack(spacing: 6) {
                    Text("OPEN TOOL")
                        .font(ClaudeFont.label(10))
                        .tracking(0.8)
                        .foregroundStyle(Claude.live)
                    if let name = activity.toolName {
                        Text(name)
                            .font(ClaudeFont.mono(11, weight: .medium))
                            .foregroundStyle(Claude.textPrimary)
                    }
                }
                Text(activity.summary)
                    .font(ClaudeFont.mono(11))
                    .foregroundStyle(Claude.textMuted)
                    .lineLimit(2)
            }
            Spacer()
            Image(systemName: "ellipsis")
                .font(.system(size: 12, weight: .bold))
                .foregroundStyle(Claude.live)
        }
        .padding(10)
        .background(Claude.live.opacity(0.08))
        .clipShape(RoundedRectangle(cornerRadius: 10))
    }

    private var feed: some View {
        let info = Pagination.info(items: orderedEvents, page: page, pageSize: pageSize)
        let slice = Array(info.slice)
        return VStack(spacing: 0) {
            ForEach(Array(slice.enumerated()), id: \.element.id) { idx, evt in
                Button {
                    selected = evt
                } label: {
                    EventRow(event: evt)
                }
                .buttonStyle(.plain)
                if idx < slice.count - 1 {
                    Divider().background(Claude.border).padding(.leading, 40)
                }
            }
        }
    }
}

private struct EventRow: View {
    let event: SessionEvent

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            iconBadge
                .padding(.top, 1)
            VStack(alignment: .leading, spacing: 2) {
                topLine
                Text(event.summary)
                    .font(font(for: event))
                    .foregroundStyle(secondaryColor)
                    .lineLimit(2)
                    .truncationMode(.tail)
            }
            Spacer()
            Text(TokenFormatter.clockTime(from: event.timestamp))
                .font(ClaudeFont.mono(10))
                .foregroundStyle(Claude.textMuted)
                .padding(.top, 1)
        }
        .padding(.vertical, 8)
        .padding(.horizontal, 4)
    }

    private var topLine: some View {
        HStack(spacing: 6) {
            Text(roleLabel.uppercased())
                .font(ClaudeFont.label(9))
                .tracking(0.6)
                .foregroundStyle(roleColor)
            if event.kind == .toolUse {
                if let n = event.toolName {
                    Text(n)
                        .font(ClaudeFont.mono(11, weight: .medium))
                        .foregroundStyle(Claude.textPrimary)
                }
                if !event.completed {
                    chip("OPEN",
                         bg: Claude.live.opacity(0.18),
                         fg: Claude.live)
                } else {
                    chip("DONE",
                         bg: Claude.Chip.successBg,
                         fg: Claude.Chip.successFg)
                }
            }
        }
    }

    private var iconBadge: some View {
        let tint = roleColor
        return ZStack {
            RoundedRectangle(cornerRadius: 7)
                .fill(tint.opacity(0.18))
            Image(systemName: iconName)
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(tint)
        }
        .frame(width: 28, height: 28)
    }

    private var iconName: String {
        switch event.kind {
        case .userMessage:       return "person.crop.circle.fill"
        case .assistantText:     return "sparkles"
        case .assistantThinking: return "brain"
        case .toolUse:           return ToolIcon.symbol(for: event.toolName ?? "")
        }
    }

    private var roleLabel: String {
        switch event.kind {
        case .userMessage:       return "you"
        case .assistantText:     return "claude"
        case .assistantThinking: return "thinking"
        case .toolUse:           return "tool"
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

    private func font(for event: SessionEvent) -> Font {
        event.kind == .toolUse
            ? ClaudeFont.mono(11)
            : ClaudeFont.body(12)
    }

    private var secondaryColor: Color {
        event.kind == .assistantThinking ? Claude.textMuted : Claude.textPrimary
    }

    private func chip(_ text: String, bg: Color, fg: Color) -> some View {
        Text(text)
            .font(ClaudeFont.label(9))
            .tracking(0.6)
            .padding(.horizontal, 5)
            .padding(.vertical, 1)
            .background(bg, in: Capsule())
            .foregroundStyle(fg)
    }
}
