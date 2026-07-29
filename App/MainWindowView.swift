// Full window. Background uses Claude.background; content stacked in scroll.

import SwiftUI
import ClaudeWatchCore

struct MainWindowView: View {
    @Environment(SessionWatcher.self) private var watcher
    @Environment(ProjectStore.self) private var projectStore
    @Environment(AppearanceStore.self) private var appearance
    @Environment(UpdaterController.self) private var updater
    @Environment(CoachingDataStore.self) private var coaching
    @Environment(FloatingPetController.self) private var pet
    @Environment(SpriteStore.self) private var sprites
    @Environment(PetCollectionStore.self) private var petCollection
    @Environment(CodexLivePoller.self) private var codex
    @Environment(PiAgentLivePoller.self) private var piAgent
    @State private var tab: Tab = .live
    @State private var liveFilter: LiveAgentFilter = .all
    @State private var showPrivacy: Bool = false
    // Sync với @AppStorage trong SpritePet — toggle áp dụng cho mọi pet instance.
    @AppStorage("PetFlippedHorizontally") private var petFlipped: Bool = true
    @AppStorage("notif.streakRisk.enabled") private var streakRiskNoti: Bool = false

    enum Tab: String, CaseIterable, Identifiable {
        case live = "Live"
        case coaching = "Coaching"
        case pets = "Pets"
        var id: String { rawValue }
    }

    var body: some View {
        VStack(spacing: 0) {
            topBar
            Divider().background(Claude.border)

            switch tab {
            case .live:
                liveTab
            case .coaching:
                CoachingReportView()
            case .pets:
                PetCollectionView()
            }
        }
        .frame(minWidth: 620, minHeight: 560)
        .background(Claude.backgroundGradient)
        .background(shortcutKeys)
        .sheet(isPresented: $showPrivacy) { PrivacyView() }
    }

    /// Invisible buttons giữ keyboardShortcut active toàn window.
    private var shortcutKeys: some View {
        VStack {
            Button { tab = .live } label: { EmptyView() }
                .keyboardShortcut("1", modifiers: .command)
                .opacity(0)
            Button { tab = .coaching } label: { EmptyView() }
                .keyboardShortcut("2", modifiers: .command)
                .opacity(0)
            Button { tab = .pets } label: { EmptyView() }
                .keyboardShortcut("3", modifiers: .command)
                .opacity(0)
        }
        .frame(width: 0, height: 0)
        .accessibilityHidden(true)
    }

    private var topBar: some View {
        HStack(alignment: .center, spacing: 16) {
            Picker("", selection: $tab) {
                ForEach(Tab.allCases) { Text($0.rawValue).tag($0) }
            }
            .pickerStyle(.segmented)
            .frame(maxWidth: 220)

            if tab == .live {
                // Pet nằm trong ProjectPickerView, ngay bên trái cụm live/pin.
                Divider().frame(height: 22)
                ProjectPickerView()
            }
            Spacer()
            // Tab Coaching + Pets không có ProjectPickerView → pet ở đây để vẫn hiện.
            if tab == .coaching || tab == .pets {
                HeaderPet()
            }
            HStack(spacing: 4) {
                themePicker
                settingsMenu
            }
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 8)
        .background(Claude.surface)
    }

    /// Settings menu: bật cập nhật, mở trang Releases, hiển thị version hiện tại.
    private var settingsMenu: some View {
        @Bindable var petBinding = pet
        return Menu {
            // Floating pet toggle — top of menu, most-used setting.
            Toggle("Floating pet trên desktop", isOn: $petBinding.isVisible)
            Toggle("Lật pet sang phải", isOn: $petFlipped)
            // v0.6.0: streak-risk notification opt-in (default OFF).
            Toggle("Nhắc khi streak sắp mất (sau 18h)", isOn: $streakRiskNoti)
            Divider()
            Button {
                updater.checkForUpdates()
            } label: {
                Label("Check for Updates…", systemImage: "arrow.down.circle")
            }
            // Gallery pet đã chuyển sang tab Pets riêng (cmd-3).
            Label("Chọn pet: xem tab Pets (⌘3)", systemImage: "info.circle")
                .foregroundStyle(Claude.textMuted)
                .disabled(true)
            Button {
                showPrivacy = true
            } label: {
                Label("Privacy & Data Access…", systemImage: "lock.shield")
            }
            Link(destination: URL(string: "https://github.com/Vt-mmm/claudewatch/releases")!) {
                Label("Mở GitHub Releases", systemImage: "link")
            }
            Divider()
            Text("Version \(updater.currentVersion)")
        } label: {
            Image(systemName: "gearshape")
                .font(.system(size: 14, weight: .medium))
                .foregroundStyle(Claude.textPrimary)
                .frame(width: 28, height: 22)
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
        .help("Settings")
    }

    @ViewBuilder
    private var themePicker: some View {
        @Bindable var binding = appearance
        Menu {
            Picker("", selection: $binding.mode) {
                ForEach(ThemeMode.allCases) { m in
                    Label(m.label, systemImage: m.icon).tag(m)
                }
            }
            .pickerStyle(.inline)
        } label: {
            Image(systemName: appearance.mode.icon)
                .font(.system(size: 14, weight: .medium))
                .foregroundStyle(Claude.textPrimary)
                .frame(width: 28, height: 22)
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
        .help("Chế độ giao diện")
    }

    @ViewBuilder
    private var liveTab: some View {
        let codexSnapshot = codex.snapshot
        let piSnapshot = piAgent.snapshot
        let claudeStats = watcher.stats
        let hasClaude = claudeStats != nil
        let hasCodex = codexSnapshot.sessionCount > 0
        let hasPiAgent = piSnapshot.sessionCount > 0
        if hasClaude || hasCodex || hasPiAgent {
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    LiveOverviewCard(
                        claudeStats: claudeStats,
                        codexSnapshot: codexSnapshot,
                        piSnapshot: piSnapshot,
                        filter: $liveFilter
                    )
                    liveAgentSections(
                        claudeStats: claudeStats,
                        codexSnapshot: codexSnapshot,
                        piSnapshot: piSnapshot
                    )
                }
                .padding(20)
            }
            .background(Claude.backgroundGradient)
        } else {
            placeholder
        }
    }

    @ViewBuilder
    private func liveAgentSections(claudeStats: SessionStats?,
                                   codexSnapshot: CodexLiveSnapshot,
                                   piSnapshot: PiAgentLiveSnapshot) -> some View {
        switch liveFilter {
        case .all:
            ForEach(liveAgentOrder(claudeStats: claudeStats,
                                   codexSnapshot: codexSnapshot,
                                   piSnapshot: piSnapshot)) { item in
                switch item.kind {
                case .all:
                    EmptyView()
                case .claude:
                    if let stats = claudeStats { claudeLiveSection(stats) }
                case .codex:
                    if codexSnapshot.sessionCount > 0 { CodexLiveCard(snapshot: codexSnapshot) }
                case .piagent:
                    if piSnapshot.sessionCount > 0 { PiAgentLiveCard(snapshot: piSnapshot) }
                }
            }
        case .claude:
            if let stats = claudeStats {
                claudeLiveSection(stats)
            } else {
                LiveEmptyAgentCard(
                    title: "Claude đang idle",
                    detail: "Chưa thấy Claude CLI/Desktop session đang cập nhật.",
                    systemImage: "moon.zzz.fill"
                )
            }
        case .codex:
            CodexLiveCard(snapshot: codexSnapshot)
        case .piagent:
            PiAgentLiveCard(snapshot: piSnapshot)
        }
    }

    @ViewBuilder
    private func claudeLiveSection(_ stats: SessionStats) -> some View {
        ClaudeLiveSessionCard(stats: stats)
        LiveActivityCard(stats: stats)
        if !stats.agents.isEmpty {
            AgentTreeList(agents: stats.agents)
        }
    }

    private func liveAgentOrder(claudeStats: SessionStats?,
                                codexSnapshot: CodexLiveSnapshot,
                                piSnapshot: PiAgentLiveSnapshot) -> [LiveAgentOrderItem] {
        [
            LiveAgentOrderItem(kind: .claude, date: claudeStats?.mtime ?? .distantPast),
            LiveAgentOrderItem(kind: .codex, date: codexSnapshot.latestSession?.lastTimestamp ?? .distantPast),
            LiveAgentOrderItem(kind: .piagent, date: piSnapshot.latestSession?.lastTimestamp ?? .distantPast)
        ]
        .filter { $0.date > .distantPast }
        .sorted { $0.date > $1.date }
    }

    private var placeholder: some View {
        VStack(spacing: 18) {
            ZStack {
                RoundedRectangle(cornerRadius: 22, style: .continuous)
                    .fill(Claude.orangeSoft)
                    .frame(width: 128, height: 128)
                SpritePet(
                    state: .sleepy,
                    characterName: petCollection.selectedId,
                    level: petCollection.pets[petCollection.selectedId]?.level ?? 1
                )
                .frame(width: 96, height: 96)
            }
            VStack(spacing: 6) {
                Text("Chưa có session nào")
                    .font(ClaudeFont.display(22))
                    .foregroundStyle(Claude.textPrimary)
                Text(placeholderText)
                    .font(ClaudeFont.body(13))
                    .foregroundStyle(Claude.textMuted)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 40)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Claude.backgroundGradient)
    }

    private var placeholderText: String {
        if projectStore.followLatest {
            return "Đang scan session agent local…\nMở Claude Code, Codex hoặc PiAgent để bắt đầu."
        }
        if let folder = projectStore.pinnedFolder {
            return "Đợi hoạt động trong \(folder.lastPathComponent)…"
        }
        return "Pin 1 folder ở trên để bắt đầu."
    }
}

enum LiveAgentFilter: String, CaseIterable, Identifiable {
    case all = "Tất cả"
    case claude = "Claude"
    case codex = "Codex"
    case piagent = "PiAgent"

    var id: String { rawValue }
}

private struct LiveAgentOrderItem: Identifiable {
    let kind: LiveAgentFilter
    let date: Date
    var id: LiveAgentFilter { kind }
}

private struct LiveOverviewCard: View {
    let claudeStats: SessionStats?
    let codexSnapshot: CodexLiveSnapshot
    let piSnapshot: PiAgentLiveSnapshot
    @Binding var filter: LiveAgentFilter

    private var activeSessions: Int {
        (claudeStats == nil ? 0 : 1) + codexSnapshot.sessionCount + piSnapshot.sessionCount
    }

    private var totalCost: Double {
        (claudeStats?.cost ?? 0) + codexSnapshot.totalCost + piSnapshot.totalCost
    }

    private var totalTokens: Int {
        (claudeStats?.totalTokens ?? 0) + codexSnapshot.totalTokens + piSnapshot.totalTokens
    }

    private var totalReasoningTokens: Int {
        (claudeStats?.reasoningTokens ?? 0)
            + codexSnapshot.totalReasoningTokens
            + piSnapshot.totalReasoningTokens
    }

    private var totalTools: Int {
        (claudeStats?.toolCalls ?? 0) + codexSnapshot.totalToolCalls + piSnapshot.totalToolCalls
    }

    private var thinkingSummary: String {
        var levels: [String] = []
        if let level = claudeStats?.thinkingLevel { levels.append(level) }
        levels.append(contentsOf: codexSnapshot.sessions.compactMap(\.thinkingLevel))
        levels.append(contentsOf: piSnapshot.sessions.compactMap(\.thinkingLevel))
        return compactBreakdown(levels)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .firstTextBaseline, spacing: 10) {
                Image(systemName: "dot.radiowaves.left.and.right")
                    .foregroundStyle(activeSessions > 0 ? Claude.live : Claude.textMuted)
                Text("Live agents")
                    .font(ClaudeFont.heading())
                    .foregroundStyle(Claude.textPrimary)
                Spacer()
                Picker("", selection: $filter) {
                    ForEach(LiveAgentFilter.allCases) { option in
                        Text(option.rawValue).tag(option)
                    }
                }
                .pickerStyle(.segmented)
                .frame(width: 240)
            }

            LazyVGrid(columns: [GridItem(.adaptive(minimum: 118), spacing: 10)],
                      alignment: .leading, spacing: 10) {
                metric("Sessions", "\(activeSessions)")
                metric("Cost", TokenFormatter.usd(totalCost))
                metric("Tokens", TokenFormatter.compact(totalTokens))
                if totalReasoningTokens > 0 {
                    metric("Reasoning", TokenFormatter.compact(totalReasoningTokens))
                }
                if !thinkingSummary.isEmpty {
                    metric("Thinking", thinkingSummary)
                }
                metric("Tools", "\(totalTools)")
            }

            HStack(spacing: 10) {
                agentButton(
                    name: "Claude",
                    active: claudeStats != nil,
                    detail: claudeDetail,
                    tint: Claude.orange,
                    target: .claude
                )
                agentButton(
                    name: "Codex",
                    active: codexSnapshot.sessionCount > 0,
                    detail: codexDetail,
                    tint: .green,
                    target: .codex
                )
                agentButton(
                    name: "PiAgent",
                    active: piSnapshot.sessionCount > 0,
                    detail: piDetail,
                    tint: .purple,
                    target: .piagent
                )
            }
        }
        .claudeCard()
    }

    private var claudeDetail: String {
        guard let s = claudeStats else { return "idle" }
        let thinking = s.thinkingLevel.map { " · think \($0)" } ?? ""
        let reasoning = s.reasoningTokens > 0 ? " · reason \(TokenFormatter.compact(s.reasoningTokens))" : ""
        return "\(TokenFormatter.compact(s.totalTokens)) tok\(reasoning)\(thinking) · \(s.toolCalls) tools"
    }

    private var codexDetail: String {
        guard codexSnapshot.sessionCount > 0 else { return "idle" }
        let reasoning = codexSnapshot.totalReasoningTokens > 0
            ? " · reason \(TokenFormatter.compact(codexSnapshot.totalReasoningTokens))"
            : ""
        let modelSuffix: String
        if let model = codexSnapshot.latestSession?.model, !model.isEmpty {
            modelSuffix = " · \(model)"
        } else {
            modelSuffix = ""
        }
        return "\(codexSnapshot.sessionCount) sessions · \(TokenFormatter.compact(codexSnapshot.totalTokens)) tok\(reasoning)\(modelSuffix)"
    }

    private var piDetail: String {
        guard piSnapshot.sessionCount > 0 else { return "idle" }
        let thinking = piSnapshot.latestSession?.thinkingLevel.map { " · think \($0)" } ?? ""
        let reasoning = piSnapshot.totalReasoningTokens > 0
            ? " · reason \(TokenFormatter.compact(piSnapshot.totalReasoningTokens))"
            : ""
        return "\(piSnapshot.namedTaskCount)/\(piSnapshot.sessionCount) named · \(TokenFormatter.compact(piSnapshot.totalTokens)) tok\(reasoning)\(thinking)"
    }

    private func metric(_ label: String, _ value: String) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            SectionLabel(text: label)
            Text(value)
                .font(ClaudeFont.mono(17, weight: .semibold))
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

    private func agentButton(name: String,
                             active: Bool,
                             detail: String,
                             tint: Color,
                             target: LiveAgentFilter) -> some View {
        Button { filter = target } label: {
            HStack(spacing: 9) {
                Circle()
                    .fill(active ? tint : Claude.textMuted)
                    .frame(width: 8, height: 8)
                VStack(alignment: .leading, spacing: 1) {
                    Text(name)
                        .font(ClaudeFont.body(12))
                        .fontWeight(.semibold)
                        .foregroundStyle(Claude.textPrimary)
                    Text(detail)
                        .font(ClaudeFont.mono(10))
                        .foregroundStyle(Claude.textMuted)
                        .lineLimit(1)
                }
                Spacer()
                if filter == target {
                    Image(systemName: "checkmark.circle.fill")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(tint)
                }
            }
            .padding(10)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(filter == target ? tint.opacity(0.10) : Claude.surfaceAlt)
            .clipShape(RoundedRectangle(cornerRadius: 8))
        }
        .buttonStyle(.plain)
    }

    private func compactBreakdown(_ values: [String]) -> String {
        var counts: [String: Int] = [:]
        for value in values {
            let cleaned = value.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !cleaned.isEmpty else { continue }
            counts[cleaned, default: 0] += 1
        }
        let ranked = counts.sorted {
            if $0.value != $1.value { return $0.value > $1.value }
            return $0.key < $1.key
        }
        return ranked.prefix(2)
            .map { $0.value > 1 ? "\($0.key) x\($0.value)" : $0.key }
            .joined(separator: ", ")
    }
}

private struct LiveEmptyAgentCard: View {
    let title: String
    let detail: String
    let systemImage: String

    var body: some View {
        HStack(spacing: 10) {
            ZStack {
                Circle().fill(Claude.surfaceAlt).frame(width: 34, height: 34)
                Image(systemName: systemImage)
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(Claude.textMuted)
            }
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(ClaudeFont.body(13))
                    .fontWeight(.medium)
                    .foregroundStyle(Claude.textPrimary)
                Text(detail)
                    .font(ClaudeFont.body(11))
                    .foregroundStyle(Claude.textMuted)
            }
            Spacer()
        }
        .claudeCard()
    }
}

private struct ClaudeLiveSessionCard: View {
    let stats: SessionStats
    @Environment(SessionWatcher.self) private var watcher

    private var projectDisplay: String {
        ProjectPath.displayPath(for: stats.projectSlug)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            header
            metadataGrid
            tokenGrid
            if !watcher.tokenHistory.isEmpty {
                TokenRateSparkline(samples: watcher.tokenHistory)
                    .frame(maxWidth: .infinity)
            }
            Divider().background(Claude.border)
            footer
        }
        .claudeCard()
    }

    private var header: some View {
        HStack(alignment: .top, spacing: 10) {
            ZStack {
                RoundedRectangle(cornerRadius: 8)
                    .fill(Claude.orangeSoft)
                Image(systemName: "circle.grid.cross.fill")
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(Claude.orange)
            }
            .frame(width: 34, height: 34)

            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 6) {
                    Text("Claude session")
                        .font(ClaudeFont.heading())
                        .foregroundStyle(Claude.textPrimary)
                    Text(stats.sessionId.prefix(8))
                        .font(ClaudeFont.mono(10, weight: .semibold))
                        .foregroundStyle(Claude.textMuted)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(Claude.surfaceAlt, in: Capsule())
                }
                Text(projectDisplay)
                    .font(ClaudeFont.body(12))
                    .foregroundStyle(Claude.textMuted)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }

            Spacer()

            VStack(alignment: .trailing, spacing: 0) {
                Text(TokenFormatter.usd(stats.cost))
                    .font(ClaudeFont.display(26).monospacedDigit())
                    .foregroundStyle(Claude.orange)
                    .contentTransition(.numericText())
                Text("estimated · list price")
                    .font(ClaudeFont.label(10))
                    .foregroundStyle(Claude.textMuted)
            }
        }
    }

    private var metadataGrid: some View {
        LazyVGrid(columns: [GridItem(.adaptive(minimum: 130), spacing: 10)],
                  alignment: .leading, spacing: 10) {
            cell("Model", stats.model.isEmpty ? "?" : stats.model, mono: true)
            cell("Family", stats.modelFamily.rawValue, tint: familyColor)
            cell("Last event", lastEventLabel, mono: true)
            cell("Agents", "\(stats.activeAgents.count) live · \(stats.agents.count) total", tint: Claude.live)
        }
    }

    private var tokenGrid: some View {
        LazyVGrid(columns: [GridItem(.adaptive(minimum: 100), spacing: 10)],
                  alignment: .leading, spacing: 10) {
            cell("Input", TokenFormatter.compact(stats.inputTokens), mono: true)
            cell("Output", TokenFormatter.compact(stats.outputTokens), mono: true)
            cell("Cache R", TokenFormatter.compact(stats.cacheReadTokens), mono: true)
            cell("Cache W", TokenFormatter.compact(stats.cacheWriteTokens), mono: true)
        }
    }

    private var footer: some View {
        HStack {
            Label("\(stats.messageCount) messages", systemImage: "text.bubble")
            Spacer()
            Label("\(stats.toolCalls) tool calls", systemImage: "wrench.and.screwdriver")
            Spacer()
            Label(TokenFormatter.compact(stats.totalTokens) + " tokens", systemImage: "number")
        }
        .font(ClaudeFont.body(11))
        .foregroundStyle(Claude.textMuted)
    }

    private var lastEventLabel: String {
        stats.lastEventAt.isEmpty ? "?" : TokenFormatter.clockTime(from: stats.lastEventAt)
    }

    private func cell(_ label: String,
                      _ value: String,
                      tint: Color = Claude.textPrimary,
                      mono: Bool = false) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            SectionLabel(text: label)
            Text(value)
                .font(mono ? ClaudeFont.mono(12, weight: .semibold) : ClaudeFont.body(12))
                .foregroundStyle(tint)
                .lineLimit(1)
                .minimumScaleFactor(0.75)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(9)
        .background(Claude.surfaceAlt)
        .clipShape(RoundedRectangle(cornerRadius: 8))
    }

    private var familyColor: Color {
        switch stats.modelFamily {
        case .opus:    return Claude.orange
        case .sonnet:  return .blue
        case .haiku:   return Claude.live
        case .fable:   return .purple
        case .gpt:     return .green
        case .unknown: return Claude.textMuted
        }
    }
}
