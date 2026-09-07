// Daily Quest engine — Duolingo-style 3 quest/day random từ pool 10.
// Deterministic seeded từ day-of-year để cùng 1 ngày user nhận cùng set quest
// (không phải refresh app sẽ random lại). Reset 00:00 local.
//
// Pure data model — không depend SwiftUI/UserDefaults. Persist handled by
// caller (PetCollectionStore).

import Foundation

public enum QuestKind: String, Codable, Sendable {
    case promptHighStar      // X prompt ≥4★
    case sessionClean        // X session không outlier
    case promptCount         // X prompt bất kỳ
    case petLevelUp          // 1 pet tăng N level
    case noOutlier           // 0 outlier session hôm nay
    case taskPromptCount     // X task prompt (isTaskPrompt = true)
    case avgStars            // avg stars >= X
}

public struct QuestTemplate: Sendable {
    public let id: String
    public let kind: QuestKind
    public let target: Int
    public let bonusXP: Int
    public let title: String
    public let description: String
}

public struct DailyQuest: Codable, Sendable, Identifiable, Equatable {
    public let id: String
    public let kind: QuestKind
    public let target: Int
    public let bonusXP: Int
    public let title: String
    public let description: String
    public var progress: Int
    public var completed: Bool
    public var claimed: Bool       // user đã nhấn claim chưa

    public var ratio: Double {
        target > 0 ? min(1.0, Double(progress) / Double(target)) : 1.0
    }
}

public enum DailyQuestEngine {

    /// Pool 10 quest. Variety: high-star + clean-session + count + level-up + avg.
    nonisolated(unsafe) public static let pool: [QuestTemplate] = [
        QuestTemplate(id: "p4star_3", kind: .promptHighStar, target: 3, bonusXP: 30,
                      title: "Quality Trio", description: "Đạt 3 prompt ≥4★"),
        QuestTemplate(id: "p4star_5", kind: .promptHighStar, target: 5, bonusXP: 50,
                      title: "Star Master", description: "Đạt 5 prompt ≥4★"),
        QuestTemplate(id: "clean_2", kind: .sessionClean, target: 2, bonusXP: 25,
                      title: "Clean Coder", description: "2 session không outlier"),
        QuestTemplate(id: "clean_4", kind: .sessionClean, target: 4, bonusXP: 50,
                      title: "Marathon", description: "4 session không outlier"),
        QuestTemplate(id: "prompt_10", kind: .promptCount, target: 10, bonusXP: 20,
                      title: "Active Day", description: "Gửi 10 prompt"),
        QuestTemplate(id: "task_5", kind: .taskPromptCount, target: 5, bonusXP: 30,
                      title: "Builder", description: "5 task prompt rõ ràng"),
        QuestTemplate(id: "pet_lv2", kind: .petLevelUp, target: 2, bonusXP: 40,
                      title: "Trainer", description: "Active pet tăng 2 level"),
        QuestTemplate(id: "pet_lv4", kind: .petLevelUp, target: 4, bonusXP: 80,
                      title: "Power Trainer", description: "Active pet tăng 4 level"),
        QuestTemplate(id: "no_outlier", kind: .noOutlier, target: 1, bonusXP: 25,
                      title: "Discipline", description: "Hôm nay 0 outlier session"),
        QuestTemplate(id: "avg_3", kind: .avgStars, target: 3, bonusXP: 35,
                      title: "Consistency", description: "Trung bình ≥3★ cho prompts hôm nay"),
    ]

    /// Pick 3 quest cho 1 ngày. Deterministic — cùng day-of-year cho cùng kết quả.
    public static func quests(for date: Date) -> [DailyQuest] {
        let cal = Calendar.current
        let day = cal.ordinality(of: .day, in: .year, for: date) ?? 1
        let year = cal.component(.year, from: date)
        let seed = day * 1000 + year

        // Linear-congruential pseudo-random — deterministic, no Date.now().
        var rng = seed
        var indices: [Int] = Array(0..<pool.count)
        var picked: [Int] = []
        for _ in 0..<3 {
            guard !indices.isEmpty else { break }
            rng = (rng * 1103515245 + 12345) & 0x7fffffff
            let i = rng % indices.count
            picked.append(indices.remove(at: i))
        }

        return picked.map { i in
            let t = pool[i]
            return DailyQuest(
                id: t.id,
                kind: t.kind,
                target: t.target,
                bonusXP: t.bonusXP,
                title: t.title,
                description: t.description,
                progress: 0,
                completed: false,
                claimed: false
            )
        }
    }
}

/// Snapshot cho 1 ngày: 3 quest + ngày tham chiếu để biết phải reset chưa.
public struct DailyQuestSnapshot: Codable, Sendable {
    public var dayKey: String       // "yyyy-MM-dd" để compare với hôm nay
    public var quests: [DailyQuest]

    public init(dayKey: String, quests: [DailyQuest]) {
        self.dayKey = dayKey
        self.quests = quests
    }

    public static func dayKey(for date: Date) -> String {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd"
        f.timeZone = .current
        return f.string(from: date)
    }
}
