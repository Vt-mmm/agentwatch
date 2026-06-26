// Vendor breakdown — 3-column stats card: Total / Claude / Codex.
// Per-vendor: session count, prompt count, total tokens, total cost.
// Cost cho Codex = 0 (subscription), nhưng vẫn show "—" để rõ semantic.

import SwiftUI
import ClaudeWatchCore

struct VendorBreakdownCard: View {
    let sessions: [SessionSummary]

    private var claudeSessions: [SessionSummary] {
        sessions.filter { $0.source.vendor == .claude }
    }

    private var codexSessions: [SessionSummary] {
        sessions.filter { $0.source.vendor == .codex }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 6) {
                Image(systemName: "person.2.crop.square.stack")
                    .foregroundStyle(Claude.orange)
                SectionLabel(text: "Agent breakdown")
                Spacer()
                Text("\(sessions.count) session")
                    .font(ClaudeFont.mono(10))
                    .foregroundStyle(Claude.textMuted)
            }

            // 3 cột grid
            HStack(spacing: 8) {
                column(
                    title: "Total",
                    color: Claude.textPrimary,
                    sessions: sessions
                )
                Divider().frame(maxHeight: 80)
                column(
                    title: "Claude",
                    color: Claude.orange,
                    sessions: claudeSessions
                )
                Divider().frame(maxHeight: 80)
                column(
                    title: "Codex",
                    color: .green,
                    sessions: codexSessions
                )
            }
        }
        .claudeCard()
    }

    @ViewBuilder
    private func column(title: String, color: Color, sessions: [SessionSummary]) -> some View {
        let agg = SessionInventory.aggregate(sessions)
        let prompts = sessions.reduce(0) { $0 + $1.promptCount }
        let tools = agg.totalToolCalls
        VStack(alignment: .leading, spacing: 4) {
            Text(title)
                .font(ClaudeFont.label(10))
                .foregroundStyle(color)
                .fontWeight(.bold)
            statRow(label: "Sessions", value: "\(sessions.count)")
            statRow(label: "Prompts",  value: "\(prompts)")
            statRow(label: "Tools",    value: "\(tools)")
            statRow(label: "Tokens",   value: TokenFormatter.compact(agg.totalTokens))
            statRow(label: "Cost",     value: agg.totalCost > 0 ? TokenFormatter.usd(agg.totalCost) : "—")
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    @ViewBuilder
    private func statRow(label: String, value: String) -> some View {
        HStack(spacing: 4) {
            Text(label)
                .font(ClaudeFont.body(10))
                .foregroundStyle(Claude.textMuted)
            Spacer()
            Text(value)
                .font(ClaudeFont.mono(11, weight: .semibold))
                .foregroundStyle(Claude.textPrimary)
        }
    }
}
