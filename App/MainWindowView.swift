// Full window. Background uses Claude.background; content stacked in scroll.

import SwiftUI
import ClaudeWatchCore

struct MainWindowView: View {
    @Environment(SessionWatcher.self) private var watcher
    @Environment(ProjectStore.self) private var projectStore
    @Environment(AppearanceStore.self) private var appearance
    @State private var tab: Tab = .live

    enum Tab: String, CaseIterable, Identifiable {
        case live = "Live"
        case coaching = "Coaching"
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
            }
        }
        .frame(minWidth: 620, minHeight: 560)
        .background(Claude.backgroundGradient)
        .background(shortcutKeys)
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
        }
        .frame(width: 0, height: 0)
        .accessibilityHidden(true)
    }

    private var topBar: some View {
        HStack(spacing: 16) {
            Picker("", selection: $tab) {
                ForEach(Tab.allCases) { Text($0.rawValue).tag($0) }
            }
            .pickerStyle(.segmented)
            .frame(maxWidth: 220)

            if tab == .live {
                Divider().frame(height: 22)
                ProjectPickerView()
            }
            Spacer()
            themePicker
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 12)
        .background(Claude.surface)
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
        if let s = watcher.stats {
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    SessionHeaderView(stats: s)
                    TokenStatsCard(stats: s)
                    LiveActivityCard(stats: s)
                    AgentTreeList(agents: s.agents)
                }
                .padding(20)
            }
            .background(Claude.backgroundGradient)
        } else {
            placeholder
        }
    }

    private var placeholder: some View {
        VStack(spacing: 18) {
            ZStack {
                RoundedRectangle(cornerRadius: 22, style: .continuous)
                    .fill(Claude.orangeSoft)
                    .frame(width: 96, height: 96)
                Image(systemName: "sparkles")
                    .font(.system(size: 40, weight: .medium))
                    .foregroundStyle(Claude.orange)
            }
            VStack(spacing: 6) {
                Text("No session yet")
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
            return "Scanning ~/.claude/projects for the most recent session…"
        }
        if let folder = projectStore.pinnedFolder {
            return "Waiting for session activity in \(folder.lastPathComponent)…"
        }
        return "Pin a folder above to begin."
    }
}
