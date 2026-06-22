// Badge catalog — Duolingo "Awards" pattern. 15 badge declarative, predicate
// đánh giá từ state snapshot (pets, trainerLevel, streakDay, etc.).
//
// Snapshot model + predicate-based unlock cho phép backfill retroactive: load
// state lúc app start, evaluate hết predicate, grant đã đạt → user upgrade
// version cũ không mất achievement.

import Foundation

/// Snapshot state để evaluate badge predicate. Pure data, không depend store.
public struct BadgeEvalState: Sendable {
    public let pets: [String: PetProgress]
    public let trainerLevel: Int
    public let streakDay: Int
    public let totalFiveStarPrompts: Int
    public let totalCleanSessions: Int   // session no outlier
    public let totalSessions: Int

    public init(pets: [String: PetProgress],
                trainerLevel: Int,
                streakDay: Int,
                totalFiveStarPrompts: Int,
                totalCleanSessions: Int,
                totalSessions: Int) {
        self.pets = pets
        self.trainerLevel = trainerLevel
        self.streakDay = streakDay
        self.totalFiveStarPrompts = totalFiveStarPrompts
        self.totalCleanSessions = totalCleanSessions
        self.totalSessions = totalSessions
    }

    public var masteredPetIds: [String] {
        pets.filter { $0.value.level >= 10 }.map(\.key)
    }
}

public struct Badge: Sendable, Identifiable {
    public let id: String
    public let title: String
    public let description: String
    public let icon: String              // SF Symbol
    public let predicate: @Sendable (BadgeEvalState) -> Bool

    public init(id: String, title: String, description: String, icon: String,
                predicate: @escaping @Sendable (BadgeEvalState) -> Bool) {
        self.id = id; self.title = title; self.description = description
        self.icon = icon; self.predicate = predicate
    }
}

public enum BadgeCatalog {

    /// 15 badge declarative — đa dạng mục tiêu để mid/long-term hook.
    public static let all: [Badge] = [
        // Pet milestones
        Badge(id: "first_pet_lv5",
              title: "First Steps",
              description: "Đưa 1 pet lên Lv 5",
              icon: "1.circle.fill") { state in
            state.pets.values.contains { $0.level >= 5 }
        },
        Badge(id: "first_pet_lv10",
              title: "Master Trainer",
              description: "Đưa 1 pet lên Lv 10",
              icon: "star.circle.fill") { state in
            !state.masteredPetIds.isEmpty
        },
        Badge(id: "five_pets_lv10",
              title: "Pentamaster",
              description: "5 pet đạt Lv 10",
              icon: "5.circle.fill") { state in
            state.masteredPetIds.count >= 5
        },
        Badge(id: "ten_pets_lv10",
              title: "Decamaster",
              description: "10 pet đạt Lv 10",
              icon: "rosette") { state in
            state.masteredPetIds.count >= 10
        },

        // Trainer level milestones
        Badge(id: "trainer_lv5",
              title: "Apprentice",
              description: "Trainer Lv 5",
              icon: "person.fill") { state in
            state.trainerLevel >= 5
        },
        Badge(id: "trainer_lv10",
              title: "Veteran",
              description: "Trainer Lv 10",
              icon: "person.fill.badge.plus") { state in
            state.trainerLevel >= 10
        },
        Badge(id: "trainer_lv20",
              title: "Sensei",
              description: "Trainer Lv 20",
              icon: "graduationcap.fill") { state in
            state.trainerLevel >= 20
        },
        Badge(id: "trainer_lv30",
              title: "Legend",
              description: "Trainer Lv 30 (max)",
              icon: "crown.fill") { state in
            state.trainerLevel >= 30
        },

        // Streak
        Badge(id: "streak_7",
              title: "Week Warrior",
              description: "Streak 7 ngày",
              icon: "flame") { state in
            state.streakDay >= 7
        },
        Badge(id: "streak_30",
              title: "Monthly Madness",
              description: "Streak 30 ngày",
              icon: "flame.fill") { state in
            state.streakDay >= 30
        },
        Badge(id: "streak_100",
              title: "Centurion",
              description: "Streak 100 ngày",
              icon: "trophy.fill") { state in
            state.streakDay >= 100
        },

        // Prompt quality
        Badge(id: "fivestar_10",
              title: "Quality Coder",
              description: "10 prompt 5★",
              icon: "star.fill") { state in
            state.totalFiveStarPrompts >= 10
        },
        Badge(id: "fivestar_100",
              title: "Star Hunter",
              description: "100 prompt 5★",
              icon: "sparkles") { state in
            state.totalFiveStarPrompts >= 100
        },

        // Clean discipline
        Badge(id: "clean_50",
              title: "Disciplined",
              description: "50 session không outlier",
              icon: "checkmark.shield") { state in
            state.totalCleanSessions >= 50
        },
        Badge(id: "clean_200",
              title: "Impeccable",
              description: "200 session không outlier",
              icon: "checkmark.shield.fill") { state in
            state.totalCleanSessions >= 200
        },
    ]

    /// Evaluate toàn bộ badges với current state → set of unlocked ids.
    public static func evaluate(_ state: BadgeEvalState) -> Set<String> {
        var result: Set<String> = []
        for b in all where b.predicate(state) {
            result.insert(b.id)
        }
        return result
    }
}
