// Session row renderer + session-level badge/pill helpers for the top sessions list.
// Dependency direction: extension on CoachingReportView, no outward dependencies.

import SwiftUI
import ClaudeWatchCore

extension CoachingReportView {

    // MARK: - Session intent classification

    /// Map source + sessionUuid → intent from the first three prompts.
    /// v0.5.0: Cursor-style "Conversation Insights" but rule-based.
    var sessionIntents: [String: SessionIntent] {
        derived.sessionIntents
    }

    // MARK: - Session row

    func sessionRow(_ s: SessionSummary) -> some View {
        let isOutlier = outlierIds.contains(s.auditKey)
        let isAgentLoop = agentLoopIds.contains(s.auditKey)
        let topRisk = riskBySession[RiskScorer.sessionKey(source: s.source, id: s.id)]
        let intent = sessionIntents[s.auditKey] ?? .general
        let alias = SessionAliasStore.shared.alias(for: s.auditKey)
        let title = alias ?? s.displayTitle
        return HStack(spacing: 10) {
            sessionSourcePill(s.source)
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    intentBadge(intent)
                    Text(title)
                        .font(ClaudeFont.body(12))
                        .fontWeight(.medium)
                        .foregroundStyle(Claude.textPrimary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                    if alias != nil || s.sessionTitle != nil {
                        Text(alias != nil ? "alias" : "task")
                            .font(ClaudeFont.mono(9, weight: .semibold))
                            .foregroundStyle(Claude.textMuted)
                            .padding(.horizontal, 5)
                            .padding(.vertical, 1)
                            .background(Claude.surfaceAlt, in: Capsule())
                    }
                    if isOutlier {
                        badge("🚨 outlier", color: .red,
                              help: "Cost vượt median/MAD baseline trong cùng agent, model và cost basis")
                    }
                    if isAgentLoop {
                        badge("⚠️ \(s.agentCount) agents", color: .orange,
                              help: "Spawn ≥10 Agent — coi chừng loop tốn token")
                    }
                    if let topRisk {
                        badge("\(topRisk.severity.shortLabel) \(topRisk.score)",
                              color: riskColor(topRisk.severity),
                              help: "\(topRisk.category.label): \(topRisk.reason)")
                    }
                }
                Text(sessionTimeRange(s))
                    .font(ClaudeFont.mono(10))
                    .foregroundStyle(Claude.textPrimary.opacity(0.75))
                    .lineLimit(1)
                if title != s.projectDisplay {
                    Text(s.projectDisplay)
                        .font(ClaudeFont.mono(10))
                        .foregroundStyle(Claude.textMuted)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
                Text(sessionMetaLabel(s))
                    .font(ClaudeFont.mono(10))
                    .foregroundStyle(Claude.textMuted)
                    .lineLimit(1)
            }
            Spacer(minLength: 8)
            Text(sessionCostLabel(s))
                .font(ClaudeFont.mono(12, weight: .semibold))
                .foregroundStyle(Claude.orange)
                .help("Cost: \(s.costBasis.label)")
        }
        .padding(.vertical, 3)
    }

    // MARK: - Badges & pills

    /// Intent classifier badge — icon + label, color theo intent enum.
    @ViewBuilder
    func intentBadge(_ intent: SessionIntent) -> some View {
        let rgb = intent.colorRGB
        let color = Color(red: rgb.r, green: rgb.g, blue: rgb.b)
        HStack(spacing: 3) {
            Image(systemName: intent.icon)
                .font(.system(size: 9, weight: .semibold))
            Text(intent.label)
                .font(ClaudeFont.mono(9, weight: .semibold))
        }
        .foregroundStyle(color)
        .padding(.horizontal, 5).padding(.vertical, 1)
        .background(color.opacity(0.15))
        .clipShape(Capsule())
        .help("Intent: \(intent.label) — heuristic dựa trên prompt đầu session")
    }

    func badge(_ text: String, color: Color, help: String) -> some View {
        Text(text)
            .font(ClaudeFont.mono(9, weight: .semibold))
            .foregroundStyle(color)
            .padding(.horizontal, 5).padding(.vertical, 1)
            .background(color.opacity(0.15))
            .clipShape(Capsule())
            .help(help)
    }

    func sessionSourcePill(_ src: SessionSource) -> some View {
        let (fg, bg) = sourcePillColors(src)
        return Text(src.shortLabel)
            .font(ClaudeFont.mono(9))
            .fontWeight(.bold)
            .foregroundStyle(fg)
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(bg)
            .clipShape(Capsule())
            .help(src.label)
    }

    private func sourcePillColors(_ src: SessionSource) -> (Color, Color) {
        switch src {
        case .cli:     return (Claude.Chip.infoFg, Claude.Chip.infoBg)
        case .desktop: return (Claude.Chip.warningFg, Claude.Chip.warningBg)
        case .codex:   return (.green, Color.green.opacity(0.15))
        case .piagent: return (.purple, Color.purple.opacity(0.15))
        }
    }

    // MARK: - Label helpers

    /// Phụ đề row: model · tokens · tools · cache hit%.
    func sessionMetaLabel(_ s: SessionSummary) -> String {
        let modelStr = s.model.isEmpty ? "?" : s.model
        let thinking = s.thinkingLevel.map { " · thinking \($0)" } ?? ""
        let reasoning = s.reasoningTokens > 0
            ? " · reasoning \(TokenFormatter.compact(s.reasoningTokens))"
            : ""
        let cache = s.cacheHitRate
        let cacheStr = cache > 0 ? " · cache \(Int(cache * 100))%" : ""
        return "\(modelStr)\(thinking) · \(TokenFormatter.compact(s.totalTokens)) tok\(reasoning) · \(s.toolCallCount) tools\(cacheStr)"
    }

    func sessionCostLabel(_ session: SessionSummary) -> String {
        switch session.costBasis {
        case .reported:
            return TokenFormatter.usd(session.cost)
        case .estimated:
            return "~" + TokenFormatter.usd(session.cost)
        case .unavailable:
            return "—"
        }
    }

    /// Format: nếu cùng 1 ngày → "12/06 10:23 → 14:55", khác ngày → "12/06 10:23 → 13/06 14:55".
    func sessionTimeRange(_ s: SessionSummary) -> String {
        let cal = Calendar.current
        let first = s.firstTimestamp ?? s.lastTimestamp ?? Date()
        let last = s.lastTimestamp ?? first
        let sameDay = cal.isDate(first, inSameDayAs: last)
        let dayHm = DateFormatter()
        dayHm.dateFormat = "dd/MM HH:mm"; dayHm.timeZone = .current
        let hm = DateFormatter()
        hm.dateFormat = "HH:mm"; hm.timeZone = .current
        if sameDay {
            return "\(dayHm.string(from: first)) → \(hm.string(from: last))"
        }
        return "\(dayHm.string(from: first)) → \(dayHm.string(from: last))"
    }
}
