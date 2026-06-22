// Daily Quest card — Duolingo-style 3 quest/day với progress bar + bonus XP claim.
// Auto-claim khi đạt target (không cần user nhấn).

import SwiftUI
import ClaudeWatchCore

struct DailyQuestCard: View {
    let quests: [DailyQuest]

    private var completedCount: Int {
        quests.filter(\.completed).count
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 6) {
                Image(systemName: completedCount == quests.count && !quests.isEmpty
                      ? "checkmark.seal.fill" : "scroll")
                    .foregroundStyle(completedCount == quests.count && !quests.isEmpty
                                     ? .green : Claude.orange)
                SectionLabel(text: "Quest hôm nay (\(completedCount)/\(quests.count))")
                Spacer()
                Text("Reset 00:00")
                    .font(ClaudeFont.mono(9))
                    .foregroundStyle(Claude.textMuted)
            }

            if quests.isEmpty {
                Text("Đang tải quest...")
                    .font(ClaudeFont.body(11))
                    .foregroundStyle(Claude.textMuted)
            } else {
                ForEach(quests) { q in
                    questRow(q)
                }
            }
        }
        .claudeCard()
    }

    @ViewBuilder
    private func questRow(_ q: DailyQuest) -> some View {
        HStack(spacing: 10) {
            Image(systemName: q.completed ? "checkmark.circle.fill" : "circle")
                .font(.system(size: 13))
                .foregroundStyle(q.completed ? .green : Claude.textMuted)
                .frame(width: 16)
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 4) {
                    Text(q.title)
                        .font(ClaudeFont.body(12))
                        .fontWeight(.semibold)
                        .foregroundStyle(Claude.textPrimary)
                        .strikethrough(q.completed, color: Claude.textMuted)
                    Spacer()
                    Text("+\(q.bonusXP) XP")
                        .font(ClaudeFont.mono(10, weight: .semibold))
                        .foregroundStyle(q.completed ? .green : Claude.orange)
                    Text("\(q.progress)/\(q.target)")
                        .font(ClaudeFont.mono(10))
                        .foregroundStyle(Claude.textMuted)
                }
                Text(q.description)
                    .font(ClaudeFont.body(11))
                    .foregroundStyle(Claude.textMuted)
                    .lineLimit(1)
                GeometryReader { geo in
                    ZStack(alignment: .leading) {
                        RoundedRectangle(cornerRadius: 2)
                            .fill(Claude.surfaceAlt)
                        RoundedRectangle(cornerRadius: 2)
                            .fill(q.completed ? Color.green : Claude.orange)
                            .frame(width: geo.size.width * q.ratio)
                    }
                }
                .frame(height: 4)
            }
        }
    }
}
