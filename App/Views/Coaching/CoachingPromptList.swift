// Prompt list card + PromptRow — paginated list of audit prompts with bookmark toggle.
// Dependency direction: extension on CoachingReportView; PromptRow is internal (used here only).

import SwiftUI
import ClaudeWatchCore

extension CoachingReportView {

    // MARK: - Prompt list card

    var promptListCard: some View {
        let info = Pagination.info(items: records, page: promptPage, pageSize: pageSize)
        return VStack(alignment: .leading, spacing: 10) {
            HStack {
                SectionLabel(text: "Prompts trong session (\(records.count))")
                Spacer()
                Paginator(page: info.page, totalPages: info.totalPages) { promptPage = $0 }
            }
            Text("Ghi nhận user prompts hợp lệ trong phiên để audit nội dung làm việc, task ngoài scope và dấu hiệu dùng agent chưa đúng.")
                .font(ClaudeFont.body(11))
                .foregroundStyle(Claude.textMuted)
            if records.isEmpty {
                Text("Không có prompt nào trong khoảng này.")
                    .font(ClaudeFont.body(13))
                    .foregroundStyle(Claude.textMuted)
                    .padding(.vertical, 20)
                    .frame(maxWidth: .infinity, alignment: .center)
            } else {
                ForEach(Array(info.slice)) { r in
                    Button {
                        selectedRecord = r
                    } label: {
                        PromptRow(record: r, risk: riskByPrompt[r.id])
                    }
                    .buttonStyle(.plain)
                }
            }
        }
        .claudeCard()
    }
}

// MARK: - PromptRow

struct PromptRow: View {
    let record: PromptRecord
    let risk: RiskFinding?
    @Environment(BookmarkStore.self) private var bookmarks

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            badge
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 8) {
                    Text(timeLabel.string(from: record.timestamp))
                        .font(ClaudeFont.mono(11))
                        .foregroundStyle(Claude.textMuted)
                    sourceBadge
                    if let risk {
                        riskBadge(risk)
                    }
                    Text(record.projectDisplay)
                        .font(ClaudeFont.body(11))
                        .foregroundStyle(Claude.textMuted)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
                Text(record.text.prefix(140))
                    .font(ClaudeFont.body(13))
                    .foregroundStyle(Claude.textPrimary)
                    .lineLimit(2)
                if record.score.isTaskPrompt && !record.score.sectionsMissing.isEmpty {
                    Text("Thiếu: " + record.score.sectionsMissing.prefix(4).map(\.label).joined(separator: ", "))
                        .font(ClaudeFont.body(11))
                        .foregroundStyle(.orange)
                        .lineLimit(1)
                }
            }
            Spacer()
            Button {
                bookmarks.toggle(record)
            } label: {
                Image(systemName: bookmarks.contains(record.id) ? "star.fill" : "star")
                    .foregroundStyle(bookmarks.contains(record.id) ? .yellow : Claude.textMuted)
                    .font(.system(size: 14))
            }
            .buttonStyle(.borderless)
            .help(bookmarks.contains(record.id) ? "Bỏ bookmark" : "Đánh dấu mẫu hay")
        }
        .padding(10)
        .background(Claude.surfaceAlt)
        .clipShape(RoundedRectangle(cornerRadius: 10))
        .contentShape(Rectangle())
    }

    @ViewBuilder
    private var sourceBadge: some View {
        let (fg, bg) = badgeColors(record.source)
        return Text("\(record.source.emoji) \(record.source.shortLabel)")
            .font(ClaudeFont.mono(10))
            .fontWeight(.semibold)
            .foregroundStyle(fg)
            .padding(.horizontal, 6)
            .padding(.vertical, 1)
            .background(bg)
            .clipShape(Capsule())
            .help(record.source.label)
    }

    private func badgeColors(_ src: SessionSource) -> (Color, Color) {
        switch src {
        case .cli:     return (Claude.Chip.infoFg, Claude.Chip.infoBg)
        case .desktop: return (Claude.Chip.warningFg, Claude.Chip.warningBg)
        case .codex:   return (.green, Color.green.opacity(0.15))
        case .piagent: return (.purple, Color.purple.opacity(0.15))
        }
    }

    private func riskBadge(_ risk: RiskFinding) -> some View {
        let color = riskColor(risk.severity)
        return Text("\(risk.severity.shortLabel) \(risk.score)")
            .font(ClaudeFont.mono(9, weight: .semibold))
            .foregroundStyle(color)
            .padding(.horizontal, 5)
            .padding(.vertical, 1)
            .background(color.opacity(0.15))
            .clipShape(Capsule())
            .help("\(risk.category.label): \(risk.reason)")
    }

    private func riskColor(_ severity: RiskSeverity) -> Color {
        switch severity {
        case .low:      return Claude.textMuted
        case .medium:   return .orange
        case .high:     return .red
        case .critical: return .purple
        }
    }

    @ViewBuilder
    private var badge: some View {
        if record.score.isTaskPrompt {
            ZStack {
                Circle().fill(Claude.orangeSoft).frame(width: 40, height: 40)
                Text("\(record.score.stars)★")
                    .font(ClaudeFont.mono(13, weight: .semibold))
                    .foregroundStyle(Claude.orange)
            }
        } else {
            ZStack {
                Circle().fill(Claude.surface).frame(width: 40, height: 40)
                Image(systemName: "arrow.turn.up.right")
                    .font(.system(size: 14, weight: .medium))
                    .foregroundStyle(Claude.textMuted)
            }
        }
    }

    /// "dd/MM HH:mm" — gồm cả ngày để week mode biết prompt thuộc ngày nào.
    private var timeLabel: DateFormatter {
        let f = DateFormatter()
        f.dateFormat = "dd/MM HH:mm"
        f.timeZone = .current
        return f
    }
}
