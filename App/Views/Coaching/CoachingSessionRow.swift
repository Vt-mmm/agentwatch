// Session row renderer + session-level badge/pill helpers for the top sessions list.
// Dependency direction: extension on CoachingReportView, no outward dependencies.

import SwiftUI
import ClaudeWatchCore

extension CoachingReportView {

    // MARK: - Session intent classification

    /// Map sessionUuid → SessionIntent, compute từ allRecords (first 3 prompts/session).
    /// v0.5.0: Cursor-style "Conversation Insights" but rule-based.
    var sessionIntents: [String: SessionIntent] {
        var bySession: [String: [PromptRecord]] = [:]
        for r in allRecords {
            bySession[r.sessionUuid, default: []].append(r)
        }
        var result: [String: SessionIntent] = [:]
        for (uuid, recs) in bySession {
            let firstPrompts = recs.sorted { $0.timestamp < $1.timestamp }
                                   .prefix(3)
                                   .map(\.text)
            result[uuid] = SessionIntentClassifier.classify(prompts: firstPrompts)
        }
        return result
    }

    // MARK: - Session row

    func sessionRow(_ s: SessionSummary) -> some View {
        let isOutlier = outlierIds.contains(s.id)
        let isAgentLoop = agentLoopIds.contains(s.id)
        let intent = sessionIntents[s.id] ?? .general
        let alias = SessionAliasStore.shared.alias(for: s.id)
        return HStack(spacing: 10) {
            sessionSourcePill(s.source)
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    intentBadge(intent)
                    Text(alias ?? s.projectDisplay)
                        .font(ClaudeFont.body(12))
                        .fontWeight(.medium)
                        .foregroundStyle(Claude.textPrimary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                    if alias != nil {
                        Text(s.projectDisplay)
                            .font(ClaudeFont.mono(9))
                            .foregroundStyle(Claude.textMuted)
                            .lineLimit(1)
                    }
                    if isOutlier {
                        badge("🚨 outlier", color: .red,
                              help: "Cost vượt mean + 2σ — đáng review")
                    }
                    if isAgentLoop {
                        badge("⚠️ \(s.agentCount) agents", color: .orange,
                              help: "Spawn ≥10 Agent — coi chừng loop tốn token")
                    }
                }
                Text(sessionTimeRange(s))
                    .font(ClaudeFont.mono(10))
                    .foregroundStyle(Claude.textPrimary.opacity(0.75))
                    .lineLimit(1)
                Text(sessionMetaLabel(s))
                    .font(ClaudeFont.mono(10))
                    .foregroundStyle(Claude.textMuted)
                    .lineLimit(1)
            }
            Spacer(minLength: 8)
            Text(TokenFormatter.usd(s.cost))
                .font(ClaudeFont.mono(12, weight: .semibold))
                .foregroundStyle(Claude.orange)
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
        let isCli = src == .cli
        return Text(isCli ? "CLI" : "Desk")
            .font(ClaudeFont.mono(9))
            .fontWeight(.bold)
            .foregroundStyle(isCli ? Claude.Chip.infoFg : Claude.Chip.warningFg)
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(isCli ? Claude.Chip.infoBg : Claude.Chip.warningBg)
            .clipShape(Capsule())
    }

    // MARK: - Label helpers

    /// Phụ đề row: model · tokens · tools · cache hit%.
    func sessionMetaLabel(_ s: SessionSummary) -> String {
        let modelStr = s.model.isEmpty ? "?" : s.model
        let cache = s.cacheHitRate
        let cacheStr = cache > 0 ? " · cache \(Int(cache * 100))%" : ""
        return "\(modelStr) · \(TokenFormatter.compact(s.totalTokens)) tok · \(s.toolCallCount) tools\(cacheStr)"
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
