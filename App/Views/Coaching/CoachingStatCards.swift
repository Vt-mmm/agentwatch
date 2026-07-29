// Stat cards: summary, token/cost, forecast, trend chart — numeric KPI displays with delta chips.
// Dependency direction: extension on CoachingReportView ← CostTrendChart (separate view file).

import SwiftUI
import ClaudeWatchCore

extension CoachingReportView {

    // MARK: - Summary card

    var summaryCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 8) {
                Image(systemName: "graduationcap.fill").foregroundStyle(Claude.orange)
                Text("Coaching · \(currentScope.label)")
                    .font(ClaudeFont.heading())
                    .foregroundStyle(Claude.textPrimary)
                Spacer()
                if isLoading {
                    ProgressView().controlSize(.small)
                } else {
                    HStack(spacing: 6) {
                        Circle().fill(Claude.live).frame(width: 6, height: 6)
                        Text("auto · cập nhật \(TokenFormatter.clockTime(from: isoStringNow))")
                            .font(ClaudeFont.label(10))
                            .foregroundStyle(Claude.textMuted)
                    }
                }
                Button { reload() } label: {
                    Image(systemName: "arrow.clockwise")
                        .font(.system(size: 11, weight: .semibold))
                }
                .buttonStyle(.borderless)
                .help("Refresh ngay")
            }
            statGridWithDelta([
                ("Sessions", "\(inventory.sessionCount)",
                  delta: Double(inventory.sessionCount - previousAggregate.sessionCount)),
                ("Prompts",  "\(stats.totalPrompts)",
                  delta: Double(stats.totalPrompts - previousPromptCount)),
                ("Task ★",   "\(stats.taskPrompts)",
                  delta: 0),
                ("Avg ★",    String(format: "%.1f", stats.avgStars),
                  delta: stats.avgStars - previousAvgStars),
                ("High risk", "\(riskSummary.highOrCriticalCount)",
                  delta: 0),
            ])
        }
        .claudeCard()
    }

    // MARK: - Token & cost card

    var tokenCostCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 8) {
                Image(systemName: "sparkles").foregroundStyle(Claude.orange)
                Text("Token & cost · \(currentScope.label)")
                    .font(ClaudeFont.heading())
                    .foregroundStyle(Claude.textPrimary)
                Spacer()
                Text(TokenFormatter.usd(inventory.totalCost))
                    .font(ClaudeFont.display(22).monospacedDigit())
                    .foregroundStyle(Claude.orange)
            }
            statGridWithDelta(tokenCostItems)
        }
        .claudeCard()
    }

    var tokenCostItems: [(String, String, delta: Double)] {
        var items: [(String, String, delta: Double)] = [
            ("Input", TokenFormatter.compact(inventory.inputTokens),
             delta: Double(inventory.inputTokens - previousAggregate.inputTokens)),
            ("Output", TokenFormatter.compact(inventory.outputTokens),
             delta: Double(inventory.outputTokens - previousAggregate.outputTokens)),
            ("Cache R", TokenFormatter.compact(inventory.cacheReadTokens),
             delta: 0),
            ("Cache W", TokenFormatter.compact(inventory.cacheWriteTokens),
             delta: 0),
            ("Total tok", TokenFormatter.compact(inventory.totalTokens),
             delta: Double(inventory.totalTokens - previousAggregate.totalTokens)),
        ]
        if inventory.reasoningTokens > 0 {
            items.append((
                "Reasoning",
                TokenFormatter.compact(inventory.reasoningTokens),
                delta: Double(inventory.reasoningTokens - previousAggregate.reasoningTokens)
            ))
        }
        if !thinkingModeSummary.isEmpty {
            items.append(("Thinking", thinkingModeSummary, delta: 0))
        }
        items.append(contentsOf: [
            ("Tool calls", "\(inventory.totalToolCalls)",
             delta: Double(inventory.totalToolCalls - previousAggregate.totalToolCalls)),
            ("Follow-up", "\(stats.followUpPrompts)", delta: 0),
            ("Msg/sess",
             inventory.sessionCount > 0
             ? "\(stats.totalPrompts / max(inventory.sessionCount, 1))"
             : "0", delta: 0),
        ])
        return items
    }

    var thinkingModeSummary: String {
        var counts: [String: Int] = [:]
        for session in sessions {
            guard let raw = session.thinkingLevel else { continue }
            let cleaned = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !cleaned.isEmpty else { continue }
            counts[cleaned, default: 0] += 1
        }
        return counts.sorted {
            if $0.value != $1.value { return $0.value > $1.value }
            return $0.key < $1.key
        }
        .prefix(3)
        .map { $0.value > 1 ? "\($0.key) x\($0.value)" : $0.key }
        .joined(separator: ", ")
    }

    // MARK: - Forecast card

    /// Burn rate + monthly forecast card — extrapolate cost từ 7 ngày gần nhất.
    var forecastCard: some View {
        let costs = dailyCostTrend.map(\.cost)
        let daily = CoachingInsights.dailyBurnRate(costs)
        let monthly = CoachingInsights.monthlyForecast(costs)
        return VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Image(systemName: "chart.line.uptrend.xyaxis.circle.fill")
                    .foregroundStyle(Claude.orange)
                Text("Forecast chi phí")
                    .font(ClaudeFont.heading())
                    .foregroundStyle(Claude.textPrimary)
                Spacer()
            }
            HStack(spacing: 16) {
                forecastCell("Burn rate / ngày", TokenFormatter.usd(daily))
                forecastCell("Forecast / tháng", TokenFormatter.usd(monthly))
                forecastCell("Forecast / năm",   TokenFormatter.usd(monthly * 12))
            }
            Text("Tính từ 7 ngày gần nhất (tính cả hôm có data). Giả định pace giữ nguyên — anh dùng để báo budget cho team, không phải số liệu cứng.")
                .font(ClaudeFont.body(10))
                .foregroundStyle(Claude.textMuted)
        }
        .claudeCard()
    }

    func forecastCell(_ label: String, _ value: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            SectionLabel(text: label)
            Text(value)
                .font(ClaudeFont.mono(16, weight: .semibold))
                .foregroundStyle(Claude.orange)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(8)
        .background(Claude.surfaceAlt)
        .clipShape(RoundedRectangle(cornerRadius: 6))
    }

    // MARK: - Trend chart card

    var trendCard: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                Image(systemName: "chart.line.uptrend.xyaxis")
                    .foregroundStyle(Claude.orange)
                Text("Cost 7 ngày gần nhất")
                    .font(ClaudeFont.heading())
                    .foregroundStyle(Claude.textPrimary)
                Spacer()
                if dailyCostTrend.contains(where: { $0.cost > 0 }) {
                    Text(TokenFormatter.usd(dailyCostTrend.reduce(0) { $0 + $1.cost }))
                        .font(ClaudeFont.mono(13, weight: .semibold))
                        .foregroundStyle(Claude.orange)
                }
            }
            CostTrendChart(buckets: dailyCostTrend)
                .frame(height: 70)
        }
        .claudeCard()
    }

    // MARK: - Stat grid helpers

    /// Adaptive grid với delta optional. Delta != 0 sẽ hiện arrow + giá trị.
    func statGridWithDelta(_ items: [(String, String, delta: Double)]) -> some View {
        LazyVGrid(columns: [GridItem(.adaptive(minimum: 110), spacing: 10)],
                  alignment: .leading, spacing: 10) {
            ForEach(items, id: \.0) { item in
                statCellWithDelta(item.0, item.1, delta: item.2)
            }
        }
    }

    /// Layout: label trên (full width) — value + delta dưới cùng hàng.
    func statCellWithDelta(_ label: String, _ value: String,
                           delta: Double) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            SectionLabel(text: label)
                .lineLimit(1)
                .minimumScaleFactor(0.85)
                .fixedSize(horizontal: false, vertical: true)
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Text(value)
                    .font(ClaudeFont.mono(18, weight: .medium))
                    .foregroundStyle(Claude.textPrimary)
                    .lineLimit(1)
                    .minimumScaleFactor(0.7)
                    .contentTransition(.numericText())
                    .animation(.snappy(duration: 0.4), value: value)
                Spacer(minLength: 4)
                if delta != 0 {
                    deltaChip(delta)
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(10)
        .background(Claude.surfaceAlt)
        .clipShape(RoundedRectangle(cornerRadius: 8))
    }

    func deltaChip(_ delta: Double) -> some View {
        let positive = delta > 0
        let color: Color = positive ? .green : .red
        let arrow = positive ? "arrow.up" : "arrow.down"
        let absVal = abs(delta)
        // Format compact: <1 → 0.x, <1000 → integer, ≥1000 → 1.2k/3.4M.
        let str: String
        if absVal < 1 {
            str = String(format: "%.1f", absVal)
        } else if absVal < 1000 {
            str = "\(Int(absVal))"
        } else {
            str = TokenFormatter.compact(Int(absVal))
        }
        return HStack(spacing: 2) {
            Image(systemName: arrow).font(.system(size: 8, weight: .bold))
            Text(str).font(ClaudeFont.mono(9, weight: .semibold))
        }
        .foregroundStyle(color)
        .padding(.horizontal, 4).padding(.vertical, 1)
        .background(color.opacity(0.15))
        .clipShape(Capsule())
        .fixedSize()
    }
}
