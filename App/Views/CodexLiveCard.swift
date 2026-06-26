// Live Codex activity card — render trong Live tab dưới Claude session card.
// Show count + latest project + token usage trong 5 phút gần đây.

import SwiftUI
import ClaudeWatchCore

struct CodexLiveCard: View {
    let snapshot: CodexLiveSnapshot

    private var isActive: Bool {
        snapshot.sessionCount > 0
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 6) {
                Image(systemName: "person.crop.circle.badge.checkmark")
                    .foregroundStyle(isActive ? .green : Claude.textMuted)
                SectionLabel(text: "Codex live (5 phút)")
                Spacer()
                if isActive {
                    HStack(spacing: 4) {
                        Circle().fill(Color.green).frame(width: 6, height: 6)
                        Text("\(snapshot.sessionCount) active")
                            .font(ClaudeFont.mono(10, weight: .semibold))
                            .foregroundStyle(.green)
                    }
                } else {
                    Text("idle")
                        .font(ClaudeFont.mono(10))
                        .foregroundStyle(Claude.textMuted)
                }
            }

            if isActive {
                if let latest = snapshot.latestSession {
                    HStack(spacing: 10) {
                        VStack(alignment: .leading, spacing: 2) {
                            Text("Latest")
                                .font(ClaudeFont.label(10))
                                .foregroundStyle(Claude.textMuted)
                            Text(latest.projectDisplay)
                                .font(ClaudeFont.body(12))
                                .fontWeight(.semibold)
                                .foregroundStyle(Claude.textPrimary)
                            if let last = latest.lastTimestamp {
                                Text(relative(last))
                                    .font(ClaudeFont.mono(10))
                                    .foregroundStyle(Claude.textMuted)
                            }
                        }
                        Spacer()
                    }
                    .padding(.vertical, 4)
                }

                HStack(spacing: 14) {
                    metric(label: "Sessions", value: "\(snapshot.sessionCount)")
                    metric(label: "Tools",    value: "\(snapshot.totalToolCalls)")
                    metric(label: "Input",    value: TokenFormatter.compact(snapshot.totalInputTokens))
                    metric(label: "Output",   value: TokenFormatter.compact(snapshot.totalOutputTokens))
                }
            } else {
                Text("Chưa có Codex session nào hoạt động trong 5 phút.")
                    .font(ClaudeFont.body(11))
                    .foregroundStyle(Claude.textMuted)
            }
        }
        .claudeCard()
    }

    @ViewBuilder
    private func metric(label: String, value: String) -> some View {
        VStack(alignment: .leading, spacing: 1) {
            Text(label)
                .font(ClaudeFont.label(9))
                .foregroundStyle(Claude.textMuted)
            Text(value)
                .font(ClaudeFont.mono(12, weight: .semibold))
                .foregroundStyle(Claude.textPrimary)
        }
    }

    private func relative(_ d: Date) -> String {
        let f = RelativeDateTimeFormatter()
        f.unitsStyle = .abbreviated
        f.locale = Locale(identifier: "vi_VN")
        return f.localizedString(for: d, relativeTo: Date())
    }
}
