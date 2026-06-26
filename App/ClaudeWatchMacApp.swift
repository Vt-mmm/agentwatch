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
    @State private var sprites = SpriteStore()
    @State private var petSocketServer = PetSocketServer()
    @State private var petCollection = PetCollectionStore()

    // v0.6.0: opt-in toggle cho streak-risk notification (default OFF).
    @AppStorage("notif.streakRisk.enabled") private var streakRiskNotificationEnabled: Bool = false
    @AppStorage("notif.streakRisk.hour") private var streakRiskHour: Int = 18

    var body: some Scene {
        WindowGroup("Agent Watch", id: "main") {
            MainWindowView()
                .environment(watcher)
                .environment(projectStore)
                .environment(appearance)
                .environment(bookmarks)
                .environment(coachingData)
                .environment(updater)
                .environment(floatingPet)
                .environment(sprites)
                .environment(petCollection)
                .preferredColorScheme(appearance.mode.colorScheme)
                .onAppear {
                    // Bắt đầu thu thập MetricKit payloads — silent, không có UI.
                    MetricsCollector.shared.start()
                    startWatchingIfPossible()
                    petBroker.attach(floatingPet)
                    // Sync floating pet từ PetCollectionStore (nguồn sự thật mới).
                    floatingPet.characterName = petCollection.selectedId
                    floatingPet.level = petCollection.pets[petCollection.selectedId]?.level ?? 1
                    // Start socket server + wire pet controller.
                    petSocketServer.petController = floatingPet
                    petSocketServer.start()
                    // Wire XP hook: mỗi lần Coaching reload xong → inject XP vào pet.
                    // [weak petCollection] để tránh retain cycle.
                    coachingData.onReloadComplete = { [weak petCollection] records, sessions, outlierIds, loopIds in
                        petCollection?.processReload(
                            records: records,
                            sessions: sessions,
                            outlierIds: outlierIds,
                            agentLoopIds: loopIds
                        )
                    }
                }
                .onChange(of: petCollection.selectedId) { _, newId in
                    floatingPet.characterName = newId
                    // Sync level khi đổi pet selection
                    floatingPet.level = petCollection.pets[newId]?.level ?? 1
                }
                .onChange(of: petCollection.pets[petCollection.selectedId]?.level) { _, newLevel in
                    // Sync level khi XP tăng → level up trong session hiện tại
                    floatingPet.level = newLevel ?? 1
                }
                .onChange(of: watcher.stats) { _, new in
                    notifications.update(with: new)
                    petBroker.observeLive(stats: new)
                }
                .onChange(of: coachingData.petState) { _, s in
                    floatingPet.state = s
                }
                .onChange(of: coachingData.lastRefreshAt) { _, _ in
                    petBroker.observe(sessions: coachingData.allSessions,
                                      activeProject: watcher.stats?.projectSlug)
                    // v0.6.0: check streak risk sau mỗi reload (opt-in toggle riêng).
                    if streakRiskNotificationEnabled {
                        notifications.checkStreakRisk(
                            streakDay: petCollection.streakDay,
                            isStale: petCollection.isStreakStaleToday,
                            notifyHour: streakRiskHour
                        )
                    }
                }
        }
        .windowResizability(.contentMinSize)
        .commands {
            // Chèn "Check for Updates…" ngay sau "About Agent Watch" trong app menu.
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
