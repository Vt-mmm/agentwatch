// Token & cost card — Claude-styled, large serif cost figure, mono digits per cell.

import SwiftUI
import ClaudeWatchCore

struct TokenStatsCard: View {
    let stats: SessionStats
    @Environment(SessionWatcher.self) private var watcher

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            header
            grid
            if !watcher.tokenHistory.isEmpty {
                TokenRateSparkline(samples: watcher.tokenHistory)
                    .frame(maxWidth: .infinity)
            }
            Divider().background(Claude.border)
            footer
        }
        .claudeCard()
    }

    private var header: some View {
        HStack(alignment: .firstTextBaseline) {
            HStack(spacing: 8) {
                Image(systemName: "sparkles")
                    .foregroundStyle(Claude.orange)
                Text("Tokens & cost")
                    .font(ClaudeFont.heading())
                    .foregroundStyle(Claude.textPrimary)
            }
            Spacer()
            VStack(alignment: .trailing, spacing: 0) {
                Text(TokenFormatter.usd(stats.cost))
                    .font(ClaudeFont.display(28).monospacedDigit())
                    .foregroundStyle(Claude.orange)
                    .contentTransition(.numericText())
                    .animation(.snappy(duration: 0.4), value: stats.cost)
                Text("estimated · list price")
                    .font(ClaudeFont.label(10))
                    .foregroundStyle(Claude.textMuted)
            }
        }
    }

    private var grid: some View {
        let cols = [GridItem(.flexible()), GridItem(.flexible()),
                    GridItem(.flexible()), GridItem(.flexible())]
        return LazyVGrid(columns: cols, spacing: 14) {
            cell("Input",    TokenFormatter.compact(stats.inputTokens))
            cell("Output",   TokenFormatter.compact(stats.outputTokens))
            cell("Cache R",  TokenFormatter.compact(stats.cacheReadTokens))
            cell("Cache W",  TokenFormatter.compact(stats.cacheWriteTokens))
        }
    }

    private func cell(_ label: String, _ value: String) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            SectionLabel(text: label)
            Text(value)
                .font(ClaudeFont.mono(18, weight: .medium))
                .foregroundStyle(Claude.textPrimary)
                .contentTransition(.numericText())
                .animation(.snappy(duration: 0.4), value: value)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(10)
        .background(Claude.surfaceAlt)
        .clipShape(RoundedRectangle(cornerRadius: 8))
    }

    private var footer: some View {
        HStack {
            Label("\(stats.messageCount) messages", systemImage: "text.bubble")
            Spacer()
            Label("\(stats.toolCalls) tool calls", systemImage: "wrench.and.screwdriver")
        }
        .font(ClaudeFont.body(11))
        .foregroundStyle(Claude.textMuted)
    }
}
