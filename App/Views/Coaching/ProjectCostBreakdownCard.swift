// Per-task/folder cost breakdown — PiAgent group theo session title, còn
// Claude/Codex group theo folder vì chưa có task title ổn định như Pi.

import SwiftUI
import ClaudeWatchCore

struct ProjectCostBreakdownCard: View {
    let sessions: [SessionSummary]

    /// Aggregate cost per task/folder per vendor.
    private struct ProjectCost: Identifiable {
        let id: String
        let project: String
        let totalCost: Double
        let claudeCost: Double
        let codexCost: Double
        let piAgentCost: Double
        let claudeSessions: Int
        let codexSessions: Int
        let piAgentSessions: Int
        let reasoningTokens: Int
        let thinkingSummary: String
        var totalSessions: Int { claudeSessions + codexSessions + piAgentSessions }
    }

    private var perProject: [ProjectCost] {
        var byProj: [
            String: (
                claude: Double, codex: Double, pi: Double,
                cs: Int, xs: Int, ps: Int,
                reasoning: Int, thinking: [String: Int]
            )
        ] = [:]
        for s in sessions {
            let key = s.source == .piagent ? s.displayTitle : s.projectDisplay
            var entry = byProj[key] ?? (0, 0, 0, 0, 0, 0, 0, [:])
            if s.source.vendor == .claude {
                entry.claude += s.cost
                entry.cs += 1
            } else if s.source.vendor == .codex {
                entry.codex += s.cost
                entry.xs += 1
            } else {
                entry.pi += s.cost
                entry.ps += 1
            }
            entry.reasoning += s.reasoningTokens
            if let level = s.thinkingLevel?.trimmingCharacters(in: .whitespacesAndNewlines),
               !level.isEmpty {
                entry.thinking[level, default: 0] += 1
            }
            byProj[key] = entry
        }
        return byProj
            .map { ProjectCost(
                id: $0.key, project: $0.key,
                totalCost: $0.value.claude + $0.value.codex + $0.value.pi,
                claudeCost: $0.value.claude,
                codexCost: $0.value.codex,
                piAgentCost: $0.value.pi,
                claudeSessions: $0.value.cs,
                codexSessions: $0.value.xs,
                piAgentSessions: $0.value.ps,
                reasoningTokens: $0.value.reasoning,
                thinkingSummary: thinkingBreakdown($0.value.thinking)
            ) }
            .sorted { $0.totalCost > $1.totalCost }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 6) {
                Image(systemName: "folder.fill.badge.gearshape")
                    .foregroundStyle(Claude.orange)
                SectionLabel(text: "Cost theo task/folder · reported + estimate")
                Spacer()
                Text("\(perProject.count) nhóm")
                    .font(ClaudeFont.mono(10))
                    .foregroundStyle(Claude.textMuted)
            }

            if perProject.isEmpty {
                Text("Chưa có session nào trong scope.")
                    .font(ClaudeFont.body(11))
                    .foregroundStyle(Claude.textMuted)
            } else {
                headerRow
                ForEach(Array(perProject.prefix(8))) { p in
                    row(p)
                }
                if perProject.count > 8 {
                    Text("… và \(perProject.count - 8) nhóm khác")
                        .font(ClaudeFont.body(10))
                        .foregroundStyle(Claude.textMuted)
                        .padding(.top, 2)
                }
            }
        }
        .claudeCard()
    }

    @ViewBuilder
    private var headerRow: some View {
        HStack(spacing: 8) {
            Text("Task/folder")
                .frame(maxWidth: .infinity, alignment: .leading)
            Text("Total").frame(width: 62, alignment: .trailing)
            Text("Claude").frame(width: 62, alignment: .trailing)
                .foregroundStyle(Claude.orange)
            Text("Codex").frame(width: 62, alignment: .trailing)
                .foregroundStyle(.green)
            Text("Pi").frame(width: 62, alignment: .trailing)
                .foregroundStyle(.purple)
        }
        .font(ClaudeFont.label(10))
        .foregroundStyle(Claude.textMuted)
        .padding(.bottom, 2)
        .overlay(alignment: .bottom) {
            Rectangle().fill(Claude.border).frame(height: 0.5)
        }
    }

    @ViewBuilder
    private func row(_ p: ProjectCost) -> some View {
        HStack(spacing: 8) {
            VStack(alignment: .leading, spacing: 1) {
                Text(displayName(p.project))
                    .font(ClaudeFont.body(11))
                    .foregroundStyle(Claude.textPrimary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                Text(projectMeta(p))
                    .font(ClaudeFont.mono(9))
                    .foregroundStyle(Claude.textMuted)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            Text(TokenFormatter.usd(p.totalCost))
                .frame(width: 62, alignment: .trailing)
                .foregroundStyle(Claude.textPrimary)

            Text(p.claudeCost > 0 ? TokenFormatter.usd(p.claudeCost) : "—")
                .frame(width: 62, alignment: .trailing)
                .foregroundStyle(p.claudeCost > 0 ? Claude.orange : Claude.textMuted)

            Text(p.codexCost > 0 ? TokenFormatter.usd(p.codexCost) : "—")
                .frame(width: 62, alignment: .trailing)
                .foregroundStyle(p.codexCost > 0 ? .green : Claude.textMuted)

            Text(p.piAgentCost > 0 ? TokenFormatter.usd(p.piAgentCost) : "—")
                .frame(width: 62, alignment: .trailing)
                .foregroundStyle(p.piAgentCost > 0 ? .purple : Claude.textMuted)
        }
        .font(ClaudeFont.mono(11, weight: .semibold))
        .padding(.vertical, 3)
    }

    /// Display folder name — nếu full path, chỉ show last 2 segments để row gọn.
    private func displayName(_ raw: String) -> String {
        guard raw.contains("/") else { return raw }
        let parts = raw.split(separator: "/").suffix(2)
        return parts.joined(separator: "/")
    }

    private func projectMeta(_ p: ProjectCost) -> String {
        var parts = ["\(p.totalSessions) session · C:\(p.claudeSessions) X:\(p.codexSessions) Pi:\(p.piAgentSessions)"]
        if p.reasoningTokens > 0 {
            parts.append("reason \(TokenFormatter.compact(p.reasoningTokens))")
        }
        if !p.thinkingSummary.isEmpty {
            parts.append("think \(p.thinkingSummary)")
        }
        return parts.joined(separator: " · ")
    }

    private func thinkingBreakdown(_ counts: [String: Int]) -> String {
        counts.sorted {
            if $0.value != $1.value { return $0.value > $1.value }
            return $0.key < $1.key
        }
        .prefix(2)
        .map { $0.value > 1 ? "\($0.key) x\($0.value)" : $0.key }
        .joined(separator: ", ")
    }
}
