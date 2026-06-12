// @main entry. Owns the shared SessionWatcher and ProjectStore.

import SwiftUI
import ClaudeWatchCore

@main
struct ClaudeWatchMacApp: App {
    @State private var watcher = SessionWatcher()
    @State private var projectStore = ProjectStore()
    @State private var notifications = NotificationService()
    @State private var appearance = AppearanceStore()
    @State private var bookmarks = BookmarkStore()
    @State private var coachingData = CoachingDataStore()
    @State private var updater = UpdaterController()
    @State private var floatingPet = FloatingPetController()
    @State private var petBroker = PetTalkBroker()

    var body: some Scene {
        WindowGroup("Claude Watch", id: "main") {
            MainWindowView()
                .environment(watcher)
                .environment(projectStore)
                .environment(appearance)
                .environment(bookmarks)
                .environment(coachingData)
                .environment(updater)
                .environment(floatingPet)
                .preferredColorScheme(appearance.mode.colorScheme)
                .onAppear {
                    startWatchingIfPossible()
                    petBroker.attach(floatingPet)
                }
                .onChange(of: watcher.stats) { _, new in
                    notifications.update(with: new)
                }
                .onChange(of: coachingData.petState) { _, s in
                    floatingPet.state = s
                }
                .onChange(of: coachingData.lastRefreshAt) { _, _ in
                    petBroker.observe(sessions: coachingData.allSessions,
                                      activeProject: watcher.stats?.projectSlug)
                }
        }
        .windowResizability(.contentMinSize)
        .commands {
            // Chèn "Check for Updates…" ngay sau "About Claude Watch" trong app menu.
            CommandGroup(after: .appInfo) {
                Button("Check for Updates…") { updater.checkForUpdates() }
            }
        }

        MenuBarExtra {
            MenuBarSummaryView()
                .environment(watcher)
                .environment(projectStore)
                .environment(appearance)
                .environment(bookmarks)
                .environment(coachingData)
                .preferredColorScheme(appearance.mode.colorScheme)
                .onAppear { startWatchingIfPossible() }
                .onChange(of: watcher.stats) { _, new in
                    notifications.update(with: new)
                }
        } label: {
            Label {
                Text(menuBarLabel)
            } icon: {
                Image(systemName: "sparkles")
            }
        }
        .menuBarExtraStyle(.window)
    }

    private var menuBarLabel: String {
        if let s = watcher.stats {
            return "$\(String(format: "%.2f", s.cost))"
        }
        return ""
    }

    private func startWatchingIfPossible() {
        guard !watcher.isWatching else { return }
        if projectStore.followLatest || projectStore.pinnedFolder == nil {
            watcher.startFollowingLatest()
        } else if let folder = projectStore.pinnedFolder {
            watcher.startPinned(folder: folder)
        }
    }
}
