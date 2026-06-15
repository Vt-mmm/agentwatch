// Insight cards: quality distribution, missing sections/gaps, project breakdown, top sessions list.
// Dependency direction: extension on CoachingReportView ← CoachingSessionRow (sessionRow helper).

import SwiftUI
import ClaudeWatchCore

extension CoachingReportView {

    // MARK: - Distribution card

    var distributionCard: some View {
        VStack(alignment: .leading, spacing: 10) {
            SectionLabel(text: "Phân bổ chất lượng (task prompts)")
            ForEach((0...5).reversed(), id: \.self) { star in
                let n = stats.starCounts[star] ?? 0
                let pct: Double = stats.taskPrompts > 0
                    ? Double(n) / Double(stats.taskPrompts) : 0
                HStack(spacing: 10) {
                    Text(starString(star))
                        .font(ClaudeFont.mono(13))
                        .foregroundStyle(Claude.textPrimary)
                        .frame(width: 60, alignment: .leading)
                    GeometryReader { geo in
                        ZStack(alignment: .leading) {
                            RoundedRectangle(cornerRadius: 4)
                                .fill(Claude.surfaceAlt)
                            RoundedRectangle(cornerRadius: 4)
                                .fill(Claude.orange)
                                .frame(width: max(2, geo.size.width * pct))
                        }
                    }
                    .frame(height: 8)
                    Text("\(n)")
                        .font(ClaudeFont.mono(12))
                        .foregroundStyle(Claude.textMuted)
                        .frame(width: 32, alignment: .trailing)
                }
            }
        }
        .claudeCard()
    }

    // MARK: - Gaps card

    var gapsCard: some View {
        VStack(alignment: .leading, spacing: 8) {
            SectionLabel(text: "Section hay thiếu nhất")
            ForEach(Array(stats.topMissingSections.enumerated()), id: \.offset) { _, item in
                HStack {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .foregroundStyle(.orange)
                    Text(item.0.label)
                        .font(ClaudeFont.body(13))
                        .fontWeight(.medium)
                        .foregroundStyle(Claude.textPrimary)
                    Spacer()
                    Text("\(item.1) prompt")
                        .font(ClaudeFont.mono(12))
                        .foregroundStyle(Claude.textMuted)
                }
                .padding(.vertical, 4)
            }
            if let topMissing = stats.topMissingSections.first {
                smartTipBlock(for: topMissing.0)
            }
        }
        .claudeCard()
    }

    /// Card gợi ý template cho section thiếu nhiều nhất — actionable, copy-paste-ready.
    func smartTipBlock(for section: SpecSection) -> some View {
        let tip = CoachingTips.tip(for: section)
        return VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                Image(systemName: "lightbulb.fill")
                    .foregroundStyle(Claude.orange)
                Text("Gợi ý template cho \"\(section.label)\"")
                    .font(ClaudeFont.body(12))
                    .fontWeight(.semibold)
                    .foregroundStyle(Claude.textPrimary)
                Spacer()
                Button {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(tip.template, forType: .string)
                } label: {
                    Label("Copy", systemImage: "doc.on.doc")
                        .font(ClaudeFont.body(11))
                }
                .buttonStyle(.borderless)
                .foregroundStyle(Claude.orange)
            }
            Text(tip.reason)
                .font(ClaudeFont.body(11))
                .foregroundStyle(Claude.textMuted)
            Text(tip.template)
                .font(ClaudeFont.mono(11))
                .foregroundStyle(Claude.textPrimary)
                .textSelection(.enabled)
                .padding(8)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(Claude.surface)
                .clipShape(RoundedRectangle(cornerRadius: 6))
        }
        .padding(.top, 8)
    }

    // MARK: - Project card

    var projectCard: some View {
        VStack(alignment: .leading, spacing: 8) {
            SectionLabel(text: "Theo project")
            ForEach(Array(stats.projectBreakdown.prefix(8).enumerated()), id: \.offset) { _, p in
                HStack {
                    Text(p.project)
                        .font(ClaudeFont.body(13))
                        .foregroundStyle(Claude.textPrimary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                    Spacer()
                    Text("\(p.count) prompts")
                        .font(ClaudeFont.mono(12))
                        .foregroundStyle(Claude.textMuted)
                    Text(String(format: "%.1f★", p.avgStars))
                        .font(ClaudeFont.mono(12, weight: .medium))
                        .foregroundStyle(Claude.orange)
                        .frame(width: 50, alignment: .trailing)
                }
                .padding(.vertical, 2)
            }
        }
        .claudeCard()
    }

    // MARK: - Top sessions card

    var topSessionsCard: some View {
        let info = Pagination.info(items: sessions, page: sessionPage, pageSize: pageSize)
        return VStack(alignment: .leading, spacing: 10) {
            HStack {
                SectionLabel(text: "Sessions theo cost (\(sessions.count))")
                Spacer()
                Paginator(page: info.page, totalPages: info.totalPages) { sessionPage = $0 }
            }
            ForEach(Array(info.slice)) { s in
                Button { selectedSession = s } label: {
                    sessionRow(s)
                }
                .buttonStyle(.plain)
            }
        }
        .claudeCard()
    }

    // MARK: - Shared helpers

    func starString(_ s: Int) -> String {
        String(repeating: "★", count: s) + String(repeating: "☆", count: 5 - s)
    }
}
