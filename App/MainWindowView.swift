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
    @State private var tab: Tab = .live
    @State private var showPrivacy: Bool = false

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
            return "Đang scan ~/.claude/projects tìm session mới nhất…\nMở 1 phiên `claude` trong terminal để bắt đầu."
        }
        if let folder = projectStore.pinnedFolder {
            return "Đợi hoạt động trong \(folder.lastPathComponent)…"
        }
        return "Pin 1 folder ở trên để bắt đầu."
    }
}
