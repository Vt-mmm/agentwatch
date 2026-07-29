// Vendor breakdown: Total / Claude / Codex / PiAgent.

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

    private var piAgentSessions: [SessionSummary] {
        sessions.filter { $0.source.vendor == .piagent }
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

            HStack(spacing: 8) {
                column(
                    title: "Total",
                    color: Claude.textPrimary,
                    sessions: sessions
                )
                Divider().frame(maxHeight: 112)
                column(
                    title: "Claude",
                    color: Claude.orange,
                    sessions: claudeSessions
                )
                Divider().frame(maxHeight: 112)
                column(
                    title: "Codex",
                    color: .green,
                    sessions: codexSessions
                )
                Divider().frame(maxHeight: 112)
                column(
                    title: "PiAgent",
                    color: .purple,
                    sessions: piAgentSessions
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
        let thinking = thinkingBreakdown(sessions)
        VStack(alignment: .leading, spacing: 4) {
            Text(title)
                .font(ClaudeFont.label(10))
                .foregroundStyle(color)
                .fontWeight(.bold)
            statRow(label: "Sessions", value: "\(sessions.count)")
            statRow(label: "Prompts",  value: "\(prompts)")
            statRow(label: "Tools",    value: "\(tools)")
            statRow(label: "Tokens",   value: TokenFormatter.compact(agg.totalTokens))
            if agg.reasoningTokens > 0 {
                statRow(label: "Reason", value: TokenFormatter.compact(agg.reasoningTokens))
            }
            if !thinking.isEmpty {
                statRow(label: "Thinking", value: thinking)
            }
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
                .lineLimit(1)
                .truncationMode(.middle)
        }
    }

    private func thinkingBreakdown(_ sessions: [SessionSummary]) -> String {
        var counts: [String: Int] = [:]
        for session in sessions {
            guard let raw = session.thinkingLevel else { continue }
            let cleaned = raw.trimmingCharacters(in: .whitespacesAndNewlines)
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
}
