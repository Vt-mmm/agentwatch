// Anomaly card — top 3 prompt/session "weird" nhất trong scope hiện tại.
// Dùng AnomalyScorer (Core) — rule-based, no ML. Click 1 row → mở
// PromptDetailSheet của representative prompt.

import SwiftUI
import ClaudeWatchCore

extension CoachingReportView {

    var riskFindings: [RiskFinding] {
        RiskScorer.evaluate(records: records, sessions: filteredSessions, limit: 50)
    }

    var riskSummary: RiskSummary {
        RiskScorer.summary(for: riskFindings)
    }

    var riskBySession: [String: RiskFinding] {
        RiskScorer.highestBySession(riskFindings)
    }

    var riskByPrompt: [String: RiskFinding] {
        RiskScorer.highestByPrompt(riskFindings)
    }

    /// Computed danh sách anomalies. Re-derive mỗi render — cheap, list nhỏ.
    var anomalies: [Anomaly] {
        AnomalyScorer.detect(in: records, limit: 3)
    }

    @ViewBuilder
    var riskCard: some View {
        if !riskFindings.isEmpty {
            VStack(alignment: .leading, spacing: 12) {
                HStack(spacing: 8) {
                    Image(systemName: "shield.lefthalf.filled.badge.checkmark")
                        .foregroundStyle(riskColor(riskSummary.maxScore >= 85 ? .critical : .high))
                    SectionLabel(text: "Risk audit (\(riskSummary.totalFindings))")
                    Spacer()
                    riskCounter("CRIT", riskSummary.criticalCount, .critical)
                    riskCounter("HIGH", riskSummary.highCount, .high)
                    riskCounter("MED", riskSummary.mediumCount, .medium)
                }

                HStack(spacing: 10) {
                    riskMetric("Max score", "\(riskSummary.maxScore)")
                    riskMetric("Sessions", "\(riskSummary.affectedSessions)")
                    riskMetric("Prompts", "\(riskSummary.affectedPrompts)")
                }

                ForEach(Array(riskFindings.prefix(8))) { finding in
                    Button {
                        openRiskFinding(finding)
                    } label: {
                        riskRow(finding)
                    }
                    .buttonStyle(.plain)
                }
            }
            .claudeCard()
        }
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
    private func riskRow(_ finding: RiskFinding) -> some View {
        let session = allSessions.first {
            $0.source == finding.source && $0.id == finding.sessionId
        }
        let title = session?.displayTitle ?? finding.projectDisplay
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: finding.category.icon)
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(riskColor(finding.severity))
                .frame(width: 22, alignment: .center)
            VStack(alignment: .leading, spacing: 5) {
                HStack(spacing: 6) {
                    Text(finding.category.label)
                        .font(ClaudeFont.body(13))
                        .fontWeight(.semibold)
                        .foregroundStyle(Claude.textPrimary)
                    Text("\(finding.score)")
                        .font(ClaudeFont.mono(10, weight: .semibold))
                        .foregroundStyle(riskColor(finding.severity))
                        .padding(.horizontal, 5).padding(.vertical, 1)
                        .background(riskColor(finding.severity).opacity(0.14))
                        .clipShape(Capsule())
                    Text(finding.source.shortLabel)
                        .font(ClaudeFont.mono(10))
                        .foregroundStyle(Claude.textMuted)
                    Spacer()
                    Text(finding.severity.shortLabel)
                        .font(ClaudeFont.mono(10, weight: .bold))
                        .foregroundStyle(riskColor(finding.severity))
                }
                Text(finding.reason)
                    .font(ClaudeFont.body(12))
                    .foregroundStyle(Claude.textMuted)
                    .lineLimit(2)
                    .fixedSize(horizontal: false, vertical: true)
                HStack(spacing: 6) {
                    Text(truncateMid(title, max: 48))
                        .font(ClaudeFont.mono(10))
                        .foregroundStyle(Claude.textMuted.opacity(0.9))
                    if let session, session.displayTitle != session.projectDisplay {
                        Text("task")
                            .font(ClaudeFont.mono(9, weight: .semibold))
                            .foregroundStyle(Claude.textMuted)
                            .padding(.horizontal, 5).padding(.vertical, 1)
                            .background(Claude.surfaceAlt)
                            .clipShape(Capsule())
                    }
                    if finding.isPromptLevel {
                        Text("prompt")
                            .font(ClaudeFont.mono(9, weight: .semibold))
                            .foregroundStyle(Claude.Chip.infoFg)
                            .padding(.horizontal, 5).padding(.vertical, 1)
                            .background(Claude.Chip.infoBg)
                            .clipShape(Capsule())
                    } else {
                        Text("session")
                            .font(ClaudeFont.mono(9, weight: .semibold))
                            .foregroundStyle(Claude.Chip.warningFg)
                            .padding(.horizontal, 5).padding(.vertical, 1)
                            .background(Claude.Chip.warningBg)
                            .clipShape(Capsule())
                    }
                }
                if !finding.evidence.isEmpty {
                    Text(truncateMid(finding.evidence, max: 150))
                        .font(ClaudeFont.mono(10))
                        .foregroundStyle(Claude.textMuted.opacity(0.75))
                        .lineLimit(1)
                }
            }
        }
        .padding(.vertical, 7)
        .padding(.horizontal, 4)
        .contentShape(Rectangle())
        .help(finding.recommendation)
    }

    private func openRiskFinding(_ finding: RiskFinding) {
        if let promptId = finding.promptId,
           let record = allRecords.first(where: { $0.id == promptId }) {
            selectedRecord = record
            return
        }
        if let session = allSessions.first(where: { $0.id == finding.sessionId }) {
            selectedSession = session
        }
    }

    private func riskCounter(_ label: String, _ count: Int,
                             _ severity: RiskSeverity) -> some View {
        Text("\(label) \(count)")
            .font(ClaudeFont.mono(10, weight: .semibold))
            .foregroundStyle(riskColor(severity))
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(riskColor(severity).opacity(count > 0 ? 0.16 : 0.07))
            .clipShape(Capsule())
    }

    private func riskMetric(_ label: String, _ value: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            SectionLabel(text: label)
            Text(value)
                .font(ClaudeFont.mono(15, weight: .semibold))
                .foregroundStyle(Claude.textPrimary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(8)
        .background(Claude.surfaceAlt)
        .clipShape(RoundedRectangle(cornerRadius: 6))
    }

    func riskColor(_ severity: RiskSeverity) -> Color {
        switch severity {
        case .low:      return Claude.textMuted
        case .medium:   return .orange
        case .high:     return .red
        case .critical: return .purple
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
