// Per-project cost breakdown — cost theo folder, gộp Claude + Codex.
// Hiển thị Top N project (mặc định 8) với 3 cột: Total / Claude / Codex.
// Folder = projectDisplay (full cwd path, đã normalize ở v0.8.1).

import SwiftUI
import ClaudeWatchCore

struct ProjectCostBreakdownCard: View {
    let sessions: [SessionSummary]

    /// Aggregate cost per project per vendor.
    private struct ProjectCost: Identifiable {
        let id: String              // == projectDisplay
        let project: String
        let totalCost: Double
        let claudeCost: Double
        let codexCost: Double
        let claudeSessions: Int
        let codexSessions: Int
        var totalSessions: Int { claudeSessions + codexSessions }
    }

    private var perProject: [ProjectCost] {
        var byProj: [String: (claude: Double, codex: Double, cs: Int, xs: Int)] = [:]
        for s in sessions {
            var entry = byProj[s.projectDisplay] ?? (0, 0, 0, 0)
            if s.source.vendor == .claude {
                entry.claude += s.cost
                entry.cs += 1
            } else {
                entry.codex += s.cost
                entry.xs += 1
            }
            byProj[s.projectDisplay] = entry
        }
        return byProj
            .map { ProjectCost(
                id: $0.key, project: $0.key,
                totalCost: $0.value.claude + $0.value.codex,
                claudeCost: $0.value.claude, codexCost: $0.value.codex,
                claudeSessions: $0.value.cs, codexSessions: $0.value.xs
            ) }
            .sorted { $0.totalCost > $1.totalCost }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 6) {
                Image(systemName: "folder.fill.badge.gearshape")
                    .foregroundStyle(Claude.orange)
                SectionLabel(text: "Cost theo folder (gộp agents)")
                Spacer()
                Text("\(perProject.count) folder")
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
                    Text("… và \(perProject.count - 8) folder khác")
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
            Text("Folder")
                .frame(maxWidth: .infinity, alignment: .leading)
            Text("Total").frame(width: 70, alignment: .trailing)
            Text("Claude").frame(width: 70, alignment: .trailing)
                .foregroundStyle(Claude.orange)
            Text("Codex").frame(width: 70, alignment: .trailing)
                .foregroundStyle(.green)
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
                Text("\(p.totalSessions) session · C:\(p.claudeSessions) X:\(p.codexSessions)")
                    .font(ClaudeFont.mono(9))
                    .foregroundStyle(Claude.textMuted)
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            Text(TokenFormatter.usd(p.totalCost))
                .frame(width: 70, alignment: .trailing)
                .foregroundStyle(Claude.textPrimary)

            Text(p.claudeCost > 0 ? TokenFormatter.usd(p.claudeCost) : "—")
                .frame(width: 70, alignment: .trailing)
                .foregroundStyle(p.claudeCost > 0 ? Claude.orange : Claude.textMuted)

            Text(p.codexCost > 0 ? TokenFormatter.usd(p.codexCost) : "—")
                .frame(width: 70, alignment: .trailing)
                .foregroundStyle(p.codexCost > 0 ? .green : Claude.textMuted)
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
}
