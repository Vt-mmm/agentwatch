// List of subagent spawns. Rows are clickable — opens AgentDetailView in a sheet.

import SwiftUI
import ClaudeWatchCore

struct AgentTreeList: View {
    let agents: [AgentSpawn]
    @State private var selectedAgent: AgentSpawn?
    @State private var page: Int = 0
    private let pageSize = 15

    /// Live agent lên đầu; completed sắp xếp mới nhất trước. Không drop cũ.
    private var ordered: [AgentSpawn] {
        let live = agents.filter { !$0.completed }
        let done = agents.filter { $0.completed }.reversed()
        return live + Array(done)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            header
            if agents.isEmpty {
                Text("No subagents spawned in this session.")
                    .foregroundStyle(Claude.textMuted)
                    .font(ClaudeFont.body())
                    .padding(.vertical, 8)
            } else {
                let info = Pagination.info(items: ordered, page: page, pageSize: pageSize)
                let slice = Array(info.slice)
                VStack(spacing: 0) {
                    ForEach(slice) { a in
                        AgentRow(agent: a) { selectedAgent = a }
                        if a.id != slice.last?.id {
                            Divider()
                                .background(Claude.border)
                                .padding(.leading, 28)
                        }
                    }
                }
            }
        }
        .claudeCard()
        .sheet(item: $selectedAgent) { agent in
            AgentDetailView(agent: agent) { selectedAgent = nil }
        }
    }

    private var header: some View {
        let info = Pagination.info(items: ordered, page: page, pageSize: pageSize)
        let active = agents.filter { !$0.completed }.count
        return HStack(spacing: 8) {
            Image(systemName: "person.2.crop.square.stack.fill")
                .foregroundStyle(Claude.orange)
            Text("Agents")
                .font(ClaudeFont.heading())
                .foregroundStyle(Claude.textPrimary)
            Spacer()
            Text("\(active) live · \(agents.count) total")
                .font(ClaudeFont.label(11))
                .foregroundStyle(Claude.textMuted)
            Paginator(page: info.page, totalPages: info.totalPages) { page = $0 }
        }
    }
}

private struct AgentRow: View {
    let agent: AgentSpawn
    let onTap: () -> Void
    @State private var isHovered = false

    var body: some View {
        Button(action: onTap) {
            HStack(spacing: 12) {
                iconBadge
                VStack(alignment: .leading, spacing: 3) {
                    HStack(spacing: 8) {
                        Text(agent.subagentType)
                            .font(ClaudeFont.mono(13, weight: .medium))
                            .foregroundStyle(Claude.textPrimary)
                        if agent.completed {
                            chip("DONE",
                                 bg: Claude.Chip.successBg,
                                 fg: Claude.Chip.successFg)
                        } else {
                            chip("LIVE",
                                 bg: Claude.live.opacity(0.18),
                                 fg: Claude.live,
                                 pulse: true)
                        }
                    }
                    if !agent.description.isEmpty {
                        Text(agent.description)
                            .font(ClaudeFont.body(12))
                            .foregroundStyle(Claude.textMuted)
                            .lineLimit(1)
                            .truncationMode(.tail)
                    }
                }
                Spacer()
                if !agent.timestamp.isEmpty {
                    Text(TokenFormatter.clockTime(from: agent.timestamp))
                        .font(ClaudeFont.mono(11))
                        .foregroundStyle(Claude.textMuted)
                }
                Image(systemName: "chevron.right")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(Claude.textMuted.opacity(isHovered ? 1 : 0.6))
            }
            .padding(.vertical, 10)
            .padding(.horizontal, 8)
            .contentShape(Rectangle())
            .background(isHovered ? Claude.surfaceAlt : Color.clear)
            .clipShape(RoundedRectangle(cornerRadius: 8))
        }
        .buttonStyle(.plain)
        .onHover { isHovered = $0 }
    }

    private var iconBadge: some View {
        let tint = AgentIcon.tint(for: agent.subagentType)
        return ZStack {
            RoundedRectangle(cornerRadius: 8)
                .fill(tint.opacity(0.18))
            Image(systemName: AgentIcon.symbol(for: agent.subagentType))
                .font(.system(size: 14, weight: .medium))
                .foregroundStyle(tint)
        }
        .frame(width: 32, height: 32)
    }

    private func chip(_ text: String, bg: Color, fg: Color,
                      pulse: Bool = false) -> some View {
        Text(text)
            .font(ClaudeFont.label(9))
            .tracking(0.6)
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(bg, in: Capsule())
            .foregroundStyle(fg)
            .opacity(pulse ? (isHovered ? 1.0 : 0.9) : 1)
    }
}
