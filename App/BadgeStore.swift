// BadgeStore — track unlocked badges + totals (5★ prompts, clean sessions).
// Backfill khi load: evaluate predicates trên state hiện tại → grant retroactive
// để user upgrade từ ver cũ không mất achievement.

import Foundation
import SwiftUI
import ClaudeWatchCore

@MainActor
@Observable
final class BadgeStore {
    private static let udUnlockedKey = "BadgeStore.unlocked.v1"
    private static let udTotalsKey = "BadgeStore.totals.v1"

    private(set) var unlockedIds: Set<String> = []
    /// Aggregate counters cập nhật theo từng reload — predicate cần.
    private(set) var totalFiveStarPrompts: Int = 0
    private(set) var totalCleanSessions: Int = 0
    private(set) var totalSessions: Int = 0

    init() {
        load()
    }

    /// Aggregate signals từ processReload — cộng dồn cap counters.
    func recordReload(newPrompts: [PromptRecord],
                      newSessions: [SessionSummary],
                      outlierIds: Set<String>) {
        for p in newPrompts where p.score.stars == 5 {
            totalFiveStarPrompts += 1
        }
        for s in newSessions {
            totalSessions += 1
            if !outlierIds.contains(s.auditKey) {
                totalCleanSessions += 1
            }
        }
        persistTotals()
    }

    /// Evaluate toàn bộ badge predicate với current state. Trả về list badge id
    /// vừa unlock lần đầu (caller dùng cho ledger log/toast).
    @discardableResult
    func evaluateAndGrant(pets: [String: PetProgress],
                          trainerLevel: Int,
                          streakDay: Int) -> [String] {
        let state = BadgeEvalState(
            pets: pets,
            trainerLevel: trainerLevel,
            streakDay: streakDay,
            totalFiveStarPrompts: totalFiveStarPrompts,
            totalCleanSessions: totalCleanSessions,
            totalSessions: totalSessions
        )
        let newlyUnlocked = BadgeCatalog.evaluate(state)
        let delta = newlyUnlocked.subtracting(unlockedIds)
        unlockedIds.formUnion(newlyUnlocked)
        if !delta.isEmpty { persistUnlocked() }
        return Array(delta)
    }

    func isUnlocked(_ badgeId: String) -> Bool {
        unlockedIds.contains(badgeId)
    }

    // MARK: - Persistence

    private func persistUnlocked() {
        UserDefaults.standard.set(Array(unlockedIds), forKey: Self.udUnlockedKey)
    }

    private func persistTotals() {
        let snap: [String: Int] = [
            "fiveStar": totalFiveStarPrompts,
            "clean": totalCleanSessions,
            "sessions": totalSessions,
        ]
        guard let data = try? JSONEncoder().encode(snap) else { return }
        UserDefaults.standard.set(data, forKey: Self.udTotalsKey)
    }

    private func load() {
        if let arr = UserDefaults.standard.array(forKey: Self.udUnlockedKey) as? [String] {
            unlockedIds = Set(arr)
        }
        if let data = UserDefaults.standard.data(forKey: Self.udTotalsKey),
           let snap = try? JSONDecoder().decode([String: Int].self, from: data) {
            totalFiveStarPrompts = snap["fiveStar"] ?? 0
            totalCleanSessions = snap["clean"] ?? 0
            totalSessions = snap["sessions"] ?? 0
        }
    }
}
