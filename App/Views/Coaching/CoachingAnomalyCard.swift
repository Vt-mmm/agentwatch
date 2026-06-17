// Anomaly card — top 3 prompt/session "weird" nhất trong scope hiện tại.
// Dùng AnomalyScorer (Core) — rule-based, no ML. Click 1 row → mở
// PromptDetailSheet của representative prompt.

import SwiftUI
import ClaudeWatchCore

extension CoachingReportView {

    /// Computed danh sách anomalies. Re-derive mỗi render — cheap, list nhỏ.
    var anomalies: [Anomaly] {
        AnomalyScorer.detect(in: records, limit: 3)
    }

    @ViewBuilder
    var anomalyCard: some View {
        if !anomalies.isEmpty {
            VStack(alignment: .leading, spacing: 10) {
                HStack(spacing: 6) {
                    Image(systemName: "magnifyingglass.circle.fill")
                        .foregroundStyle(.orange)
                    SectionLabel(text: "Cần review (\(anomalies.count))")
                }
                ForEach(anomalies) { a in
                    Button {
                        selectedRecord = a.representative
                    } label: {
                        anomalyRow(a)
                    }
                    .buttonStyle(.plain)
                }
            }
            .claudeCard()
        }
    }

    @ViewBuilder
    private func anomalyRow(_ a: Anomaly) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: a.kind.icon)
                .font(.system(size: 16))
                .foregroundStyle(.orange)
                .frame(width: 22, alignment: .center)
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 6) {
                    Text(a.kind.label)
                        .font(ClaudeFont.body(13))
                        .fontWeight(.semibold)
                        .foregroundStyle(Claude.textPrimary)
                    if a.count > 1 {
                        Text("×\(a.count)")
                            .font(ClaudeFont.mono(11))
                            .foregroundStyle(Claude.textMuted)
                    }
                    Spacer()
                    Text(starString(a.representative.score.stars))
                        .font(ClaudeFont.mono(11))
                        .foregroundStyle(Claude.textMuted)
                }
                Text(a.reason)
                    .font(ClaudeFont.body(12))
                    .foregroundStyle(Claude.textMuted)
                    .lineLimit(3)
                    .fixedSize(horizontal: false, vertical: true)
                Text(truncateMid(a.representative.text, max: 120))
                    .font(ClaudeFont.mono(11))
                    .foregroundStyle(Claude.textMuted.opacity(0.8))
                    .lineLimit(1)
            }
        }
        .padding(.vertical, 6)
        .padding(.horizontal, 4)
        .contentShape(Rectangle())
    }
}
