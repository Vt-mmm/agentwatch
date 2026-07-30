// Recent Codex/PiAgent log cards for the Sessions tab.
// Keep them lightweight: render aggregate metrics + capped recent-session lists.

import SwiftUI
import ClaudeWatchCore

struct CodexLiveCard: View {
    let snapshot: CodexLiveSnapshot
    @State private var selectedSession: SessionSummary?

    private var isActive: Bool { snapshot.sessionCount > 0 }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            header
            if isActive {
                latestBlock
                metricGrid
                recentSessions
            } else {
                idleBlock
            }
        }
        .claudeCard()
        .sheet(item: $selectedSession) { session in
            SessionDetailSheet(session: session)
        }
    }

    private var header: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Image(systemName: "sparkles.rectangle.stack.fill")
                .foregroundStyle(isActive ? .green : Claude.textMuted)
            Text("Codex logs")
                .font(ClaudeFont.heading())
                .foregroundStyle(Claude.textPrimary)
            Text("snapshot")
                .font(ClaudeFont.mono(10, weight: .semibold))
                .foregroundStyle(Claude.textMuted)
                .padding(.horizontal, 6)
                .padding(.vertical, 2)
                .background(Claude.surfaceAlt, in: Capsule())
            Spacer()
            VStack(alignment: .trailing, spacing: 0) {
                Text("~" + TokenFormatter.usd(snapshot.totalCost))
                    .font(ClaudeFont.display(24).monospacedDigit())
                    .foregroundStyle(isActive ? .green : Claude.textMuted)
                    .contentTransition(.numericText())
                Text(isActive ? "\(snapshot.sessionCount) logs" : "empty")
                    .font(ClaudeFont.label(10))
                    .foregroundStyle(isActive ? .green : Claude.textMuted)
            }
        }
    }

    @ViewBuilder
    private var latestBlock: some View {
        if let latest = snapshot.latestSession {
            Button {
                selectedSession = latest
            } label: {
                HStack(alignment: .top, spacing: 10) {
                    sessionBadge(for: latest)
                    VStack(alignment: .leading, spacing: 4) {
                        HStack(spacing: 6) {
                            Text("Latest")
                                .font(ClaudeFont.label(10))
                                .foregroundStyle(Claude.textMuted)
                            Text(latest.model.isEmpty ? "openai" : latest.model)
                                .font(ClaudeFont.mono(10, weight: .semibold))
                                .foregroundStyle(.green)
                                .padding(.horizontal, 5)
                                .padding(.vertical, 1)
                                .background(Color.green.opacity(0.13), in: Capsule())
                            if latest.reasoningTokens > 0 {
                                Text("reason \(TokenFormatter.compact(latest.reasoningTokens))")
                                    .font(ClaudeFont.mono(10, weight: .semibold))
                                    .foregroundStyle(.green)
                                    .padding(.horizontal, 5)
                                    .padding(.vertical, 1)
                                    .background(Color.green.opacity(0.10), in: Capsule())
                            }
                            if let thinking = latest.thinkingLevel {
                                Text("think \(thinking)")
                                    .font(ClaudeFont.mono(10, weight: .semibold))
                                    .foregroundStyle(.green)
                                    .padding(.horizontal, 5)
                                    .padding(.vertical, 1)
                                    .background(Color.green.opacity(0.10), in: Capsule())
                            }
                        }
                        Text(latest.displayTitle)
                            .font(ClaudeFont.body(13))
                            .fontWeight(.semibold)
                            .foregroundStyle(Claude.textPrimary)
                            .lineLimit(1)
                            .truncationMode(.middle)
                        if latest.displayTitle != latest.projectDisplay {
                            Text(latest.projectDisplay)
                                .font(ClaudeFont.mono(10))
                                .foregroundStyle(Claude.textMuted)
                                .lineLimit(1)
                                .truncationMode(.middle)
                        }
                        Text(latestMeta(latest))
                            .font(ClaudeFont.mono(10))
                            .foregroundStyle(Claude.textMuted)
                    }
                    Spacer()
                    Image(systemName: "chevron.right")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(Claude.textMuted)
                        .padding(.top, 18)
                }
                .padding(10)
                .background(Color.green.opacity(0.07))
                .clipShape(RoundedRectangle(cornerRadius: 8))
            }
            .buttonStyle(.plain)
        }
    }

    private var metricGrid: some View {
        LazyVGrid(columns: [GridItem(.adaptive(minimum: 92), spacing: 10)],
                  alignment: .leading, spacing: 10) {
            metric("Sessions", "\(snapshot.sessionCount)")
            metric("Total tok", TokenFormatter.compact(snapshot.totalTokens))
            if snapshot.totalReasoningTokens > 0 {
                metric("Reasoning", TokenFormatter.compact(snapshot.totalReasoningTokens))
            }
            metric("Input", TokenFormatter.compact(snapshot.totalInputTokens))
            metric("Output", TokenFormatter.compact(snapshot.totalOutputTokens))
            metric("Cache R", TokenFormatter.compact(snapshot.totalCacheReadTokens))
            metric("Cache W", TokenFormatter.compact(snapshot.totalCacheWriteTokens))
            metric("Tools", "\(snapshot.totalToolCalls)")
        }
    }

    @ViewBuilder
    private var recentSessions: some View {
        if !snapshot.sessions.isEmpty {
            VStack(alignment: .leading, spacing: 0) {
                HStack {
                    SectionLabel(text: "Recent Codex sessions")
                    Spacer()
                    Text("\(min(snapshot.sessions.count, 4)) / \(snapshot.sessions.count)")
                        .font(ClaudeFont.mono(10))
                        .foregroundStyle(Claude.textMuted)
                }
                .padding(.bottom, 4)

                ForEach(Array(snapshot.sessions.prefix(4).enumerated()), id: \.offset) { idx, session in
                    Button {
                        selectedSession = session
                    } label: {
                        codexSessionRow(session)
                    }
                    .buttonStyle(.plain)
                    if idx < min(snapshot.sessions.count, 4) - 1 {
                        Divider().background(Claude.border).padding(.leading, 34)
                    }
                }
            }
        }
    }

    private var idleBlock: some View {
        HStack(spacing: 10) {
            ZStack {
                Circle().fill(Claude.surfaceAlt).frame(width: 34, height: 34)
                Image(systemName: "moon.zzz.fill")
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(Claude.textMuted)
            }
            VStack(alignment: .leading, spacing: 2) {
                Text("Chưa có Codex log trong snapshot")
                    .font(ClaudeFont.body(13))
                    .fontWeight(.medium)
                    .foregroundStyle(Claude.textPrimary)
                Text("Bấm refresh để đọc lại các session Codex mới nhất.")
                    .font(ClaudeFont.body(11))
                    .foregroundStyle(Claude.textMuted)
            }
            Spacer()
        }
        .padding(10)
        .background(Claude.surfaceAlt)
        .clipShape(RoundedRectangle(cornerRadius: 8))
    }

    private func metric(_ label: String, _ value: String) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            SectionLabel(text: label)
            Text(value)
                .font(ClaudeFont.mono(16, weight: .semibold))
                .foregroundStyle(Claude.textPrimary)
                .lineLimit(1)
                .minimumScaleFactor(0.75)
                .contentTransition(.numericText())
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(9)
        .background(Claude.surfaceAlt)
        .clipShape(RoundedRectangle(cornerRadius: 8))
    }

    private func codexSessionRow(_ session: SessionSummary) -> some View {
        HStack(spacing: 9) {
            sessionBadge(for: session)
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(session.displayTitle)
                        .font(ClaudeFont.body(12))
                        .fontWeight(.medium)
                        .foregroundStyle(Claude.textPrimary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                    Text(session.model.isEmpty ? "openai" : session.model)
                        .font(ClaudeFont.mono(9, weight: .semibold))
                        .foregroundStyle(.green)
                        .padding(.horizontal, 5)
                        .padding(.vertical, 1)
                        .background(Color.green.opacity(0.13), in: Capsule())
                    if let thinking = session.thinkingLevel {
                        Text("think \(thinking)")
                            .font(ClaudeFont.mono(9, weight: .semibold))
                            .foregroundStyle(.green)
                            .padding(.horizontal, 5)
                            .padding(.vertical, 1)
                            .background(Color.green.opacity(0.10), in: Capsule())
                    }
                }
                if session.displayTitle != session.projectDisplay {
                    Text(session.projectDisplay)
                        .font(ClaudeFont.mono(10))
                        .foregroundStyle(Claude.textMuted)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
                Text(latestMeta(session))
                    .font(ClaudeFont.mono(10))
                    .foregroundStyle(Claude.textMuted)
                    .lineLimit(1)
            }
            Spacer(minLength: 8)
            Text(sessionCostLabel(session))
                .font(ClaudeFont.mono(12, weight: .semibold))
                .foregroundStyle(.green)
        }
        .padding(.vertical, 7)
        .padding(.horizontal, 4)
        .contentShape(Rectangle())
    }

    private func sessionCostLabel(_ session: SessionSummary) -> String {
        switch session.costBasis {
        case .reported:    return TokenFormatter.usd(session.cost)
        case .estimated:   return "~" + TokenFormatter.usd(session.cost)
        case .unavailable: return "—"
        }
    }

    private func sessionBadge(for session: SessionSummary) -> some View {
        let fresh = Date().timeIntervalSince(session.lastTimestamp ?? .distantPast) < 86_400
        return ZStack {
            RoundedRectangle(cornerRadius: 7)
                .fill((fresh ? Color.green : Claude.textMuted).opacity(0.16))
            Circle()
                .fill(fresh ? Color.green : Claude.textMuted)
                .frame(width: 8, height: 8)
        }
        .frame(width: 28, height: 28)
    }

    private func latestMeta(_ session: SessionSummary) -> String {
        let last = session.lastTimestamp.map(relative) ?? "unknown"
        let tokens = TokenFormatter.compact(session.totalTokens)
        let thinking = session.thinkingLevel.map { " · think \($0)" } ?? ""
        let reasoning = session.reasoningTokens > 0
            ? " · reason \(TokenFormatter.compact(session.reasoningTokens))"
            : ""
        return "\(last) · \(tokens) tok\(reasoning)\(thinking) · \(session.toolCallCount) tools · \(session.promptCount) prompts"
    }

    private func relative(_ date: Date) -> String {
        let f = RelativeDateTimeFormatter()
        f.unitsStyle = .abbreviated
        f.locale = Locale(identifier: "vi_VN")
        return f.localizedString(for: date, relativeTo: Date())
    }
}

struct PiAgentLiveCard: View {
    let snapshot: PiAgentLiveSnapshot
    @State private var selectedSession: SessionSummary?

    private var isActive: Bool { snapshot.sessionCount > 0 }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            header
            if isActive {
                latestBlock
                metricGrid
                recentSessions
            } else {
                idleBlock
            }
        }
        .claudeCard()
        .sheet(item: $selectedSession) { session in
            SessionDetailSheet(session: session)
        }
    }

    private var header: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Image(systemName: "tag.circle.fill")
                .foregroundStyle(isActive ? .purple : Claude.textMuted)
            Text("PiAgent logs")
                .font(ClaudeFont.heading())
                .foregroundStyle(Claude.textPrimary)
            Text("snapshot")
                .font(ClaudeFont.mono(10, weight: .semibold))
                .foregroundStyle(Claude.textMuted)
                .padding(.horizontal, 6)
                .padding(.vertical, 2)
                .background(Claude.surfaceAlt, in: Capsule())
            Spacer()
            VStack(alignment: .trailing, spacing: 0) {
                Text(piCostLabel)
                    .font(ClaudeFont.display(24).monospacedDigit())
                    .foregroundStyle(isActive ? .purple : Claude.textMuted)
                    .contentTransition(.numericText())
                Text(isActive ? "\(snapshot.namedTaskCount)/\(snapshot.sessionCount) named" : "empty")
                    .font(ClaudeFont.label(10))
                    .foregroundStyle(isActive ? .purple : Claude.textMuted)
            }
        }
    }

    @ViewBuilder
    private var latestBlock: some View {
        if let latest = snapshot.latestSession {
            Button {
                selectedSession = latest
            } label: {
                HStack(alignment: .top, spacing: 10) {
                    sessionBadge(for: latest)
                    VStack(alignment: .leading, spacing: 4) {
                        HStack(spacing: 6) {
                            Text(latest.hasTaskSessionTitle ? "Named task" : "Needs name")
                                .font(ClaudeFont.label(10))
                                .foregroundStyle(latest.hasTaskSessionTitle ? .purple : .orange)
                            Text(latest.model.isEmpty ? "unknown" : latest.model)
                                .font(ClaudeFont.mono(10, weight: .semibold))
                                .foregroundStyle(.purple)
                                .padding(.horizontal, 5)
                                .padding(.vertical, 1)
                                .background(Color.purple.opacity(0.13), in: Capsule())
                            if let thinking = latest.thinkingLevel {
                                Text("think \(thinking)")
                                    .font(ClaudeFont.mono(10, weight: .semibold))
                                    .foregroundStyle(.purple)
                                    .padding(.horizontal, 5)
                                    .padding(.vertical, 1)
                                    .background(Color.purple.opacity(0.10), in: Capsule())
                            }
                        }
                        Text(latest.displayTitle)
                            .font(ClaudeFont.body(13))
                            .fontWeight(.semibold)
                            .foregroundStyle(Claude.textPrimary)
                            .lineLimit(1)
                            .truncationMode(.middle)
                        if latest.displayTitle != latest.projectDisplay {
                            Text(latest.projectDisplay)
                                .font(ClaudeFont.mono(10))
                                .foregroundStyle(Claude.textMuted)
                                .lineLimit(1)
                                .truncationMode(.middle)
                        }
                        Text(latestMeta(latest))
                            .font(ClaudeFont.mono(10))
                            .foregroundStyle(Claude.textMuted)
                    }
                    Spacer()
                    Image(systemName: "chevron.right")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(Claude.textMuted)
                        .padding(.top, 18)
                }
                .padding(10)
                .background(Color.purple.opacity(0.07))
                .clipShape(RoundedRectangle(cornerRadius: 8))
            }
            .buttonStyle(.plain)
        }
    }

    private var metricGrid: some View {
        LazyVGrid(columns: [GridItem(.adaptive(minimum: 92), spacing: 10)],
                  alignment: .leading, spacing: 10) {
            metric("Sessions", "\(snapshot.sessionCount)")
            metric("Named", "\(snapshot.namedTaskCount)")
            metric("Total tok", TokenFormatter.compact(snapshot.totalTokens))
            metric("Reasoning", TokenFormatter.compact(snapshot.totalReasoningTokens))
            metric("Input", TokenFormatter.compact(snapshot.totalInputTokens))
            metric("Output", TokenFormatter.compact(snapshot.totalOutputTokens))
            metric("Tools", "\(snapshot.totalToolCalls)")
        }
    }

    private var piCostLabel: String {
        if snapshot.reportedCost > 0 && snapshot.estimatedCost > 0 {
            return TokenFormatter.usd(snapshot.totalCost) + " mix"
        }
        if snapshot.estimatedCost > 0 {
            return "~" + TokenFormatter.usd(snapshot.totalCost)
        }
        return snapshot.reportedCost > 0 ? TokenFormatter.usd(snapshot.totalCost) : "—"
    }

    @ViewBuilder
    private var recentSessions: some View {
        if !snapshot.sessions.isEmpty {
            VStack(alignment: .leading, spacing: 0) {
                HStack {
                    SectionLabel(text: "Recent PiAgent sessions")
                    Spacer()
                    Text("\(min(snapshot.sessions.count, 4)) / \(snapshot.sessions.count)")
                        .font(ClaudeFont.mono(10))
                        .foregroundStyle(Claude.textMuted)
                }
                .padding(.bottom, 4)

                ForEach(Array(snapshot.sessions.prefix(4).enumerated()), id: \.offset) { idx, session in
                    Button {
                        selectedSession = session
                    } label: {
                        piSessionRow(session)
                    }
                    .buttonStyle(.plain)
                    if idx < min(snapshot.sessions.count, 4) - 1 {
                        Divider().background(Claude.border).padding(.leading, 34)
                    }
                }
            }
        }
    }

    private var idleBlock: some View {
        HStack(spacing: 10) {
            ZStack {
                Circle().fill(Claude.surfaceAlt).frame(width: 34, height: 34)
                Image(systemName: "moon.zzz.fill")
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(Claude.textMuted)
            }
            VStack(alignment: .leading, spacing: 2) {
                Text("Chưa có PiAgent log trong snapshot")
                    .font(ClaudeFont.body(13))
                    .fontWeight(.medium)
                    .foregroundStyle(Claude.textPrimary)
                Text("Bấm refresh để đọc lại các session PiAgent mới nhất.")
                    .font(ClaudeFont.body(11))
                    .foregroundStyle(Claude.textMuted)
            }
            Spacer()
        }
        .padding(10)
        .background(Claude.surfaceAlt)
        .clipShape(RoundedRectangle(cornerRadius: 8))
    }

    private func metric(_ label: String, _ value: String) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            SectionLabel(text: label)
            Text(value)
                .font(ClaudeFont.mono(16, weight: .semibold))
                .foregroundStyle(Claude.textPrimary)
                .lineLimit(1)
                .minimumScaleFactor(0.75)
                .contentTransition(.numericText())
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(9)
        .background(Claude.surfaceAlt)
        .clipShape(RoundedRectangle(cornerRadius: 8))
    }

    private func piSessionRow(_ session: SessionSummary) -> some View {
        HStack(spacing: 9) {
            sessionBadge(for: session)
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(session.displayTitle)
                        .font(ClaudeFont.body(12))
                        .fontWeight(.medium)
                        .foregroundStyle(Claude.textPrimary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                    Text(session.hasTaskSessionTitle ? "named" : "needs name")
                        .font(ClaudeFont.mono(9, weight: .semibold))
                        .foregroundStyle(session.hasTaskSessionTitle ? .purple : .orange)
                        .padding(.horizontal, 5)
                        .padding(.vertical, 1)
                        .background((session.hasTaskSessionTitle ? Color.purple : Color.orange).opacity(0.13), in: Capsule())
                }
                Text(latestMeta(session))
                    .font(ClaudeFont.mono(10))
                    .foregroundStyle(Claude.textMuted)
                    .lineLimit(1)
            }
            Spacer(minLength: 8)
            Text(sessionCostLabel(session))
                .font(ClaudeFont.mono(12, weight: .semibold))
                .foregroundStyle(.purple)
        }
        .padding(.vertical, 7)
        .padding(.horizontal, 4)
        .contentShape(Rectangle())
    }

    private func sessionCostLabel(_ session: SessionSummary) -> String {
        switch session.costBasis {
        case .reported:    return TokenFormatter.usd(session.cost)
        case .estimated:   return "~" + TokenFormatter.usd(session.cost)
        case .unavailable: return "—"
        }
    }

    private func sessionBadge(for session: SessionSummary) -> some View {
        let fresh = Date().timeIntervalSince(session.lastTimestamp ?? .distantPast) < 86_400
        return ZStack {
            RoundedRectangle(cornerRadius: 7)
                .fill((fresh ? Color.purple : Claude.textMuted).opacity(0.16))
            Circle()
                .fill(fresh ? Color.purple : Claude.textMuted)
                .frame(width: 8, height: 8)
        }
        .frame(width: 28, height: 28)
    }

    private func latestMeta(_ session: SessionSummary) -> String {
        let last = session.lastTimestamp.map(relative) ?? "unknown"
        let tokens = TokenFormatter.compact(session.totalTokens)
        let thinking = session.thinkingLevel.map { " · think \($0)" } ?? ""
        let reasoning = session.reasoningTokens > 0
            ? " · reason \(TokenFormatter.compact(session.reasoningTokens))"
            : ""
        return "\(last) · \(tokens) tok\(reasoning)\(thinking) · \(session.toolCallCount) tools · \(session.promptCount) prompts"
    }

    private func relative(_ date: Date) -> String {
        let f = RelativeDateTimeFormatter()
        f.unitsStyle = .abbreviated
        f.locale = Locale(identifier: "vi_VN")
        return f.localizedString(for: date, relativeTo: Date())
    }
}
