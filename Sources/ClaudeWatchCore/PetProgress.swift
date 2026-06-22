// Model dữ liệu tiến trình pet — Codable/Sendable để persist qua UserDefaults JSON.
// Phase 1: chỉ dùng characterId + unlockedAt + lastSeenAt.
// Phase 2 sẽ activate xp/level/prestigeCount (reserved, default 0).

import Foundation

/// Tiến trình 1 pet cụ thể — giữ sẵn field XP/level cho phase 2.
public struct PetProgress: Codable, Sendable, Equatable {
    public var characterId: String
    /// Kinh nghiệm tích lũy — cộng dồn qua mỗi reload Coaching.
    public var xp: Int
    /// Cache derived value — recompute via XPEngine.level(forTotalXP:) when xp changes.
    public var level: Int
    /// Prestige count — dự phòng phase tương lai.
    public var prestigeCount: Int
    /// nil = chưa unlock (phase 1: tất cả unlock mặc định).
    public var unlockedAt: Date?
    /// Lần cuối user xem / chọn pet này.
    public var lastSeenAt: Date?

    /// Chuỗi hiển thị ngắn gọn cho UI badge.
    public var levelDescription: String { "Lv \(level)" }

    public init(
        characterId: String,
        xp: Int = 0,
        level: Int = 1,
        prestigeCount: Int = 0,
        unlockedAt: Date? = Date(),
        lastSeenAt: Date? = nil
    ) {
        self.characterId = characterId
        self.xp = xp
        self.level = level
        self.prestigeCount = prestigeCount
        self.unlockedAt = unlockedAt
        self.lastSeenAt = lastSeenAt
    }
}

/// Snapshot toàn bộ collection — đây là root object persist vào UserDefaults.
///
/// Schema versions:
///   v1: pets + selectedId
///   v2: + trainerXP (Trainer Lv axis) + achievedPetIds (Set pet đã PL=10
///       để không double-count achievement XP)
public struct PetCollection: Codable, Sendable {
    public static let currentSchemaVersion = 2

    public var schemaVersion: Int
    public var pets: [String: PetProgress]
    public var selectedId: String
    /// Tổng trainer XP — derive trainerLevel via TrainerProgress.level(forTotalXP:).
    public var trainerXP: Int
    /// Pet đã đạt PL=10 và đã trao achievement bonus (tránh double-count).
    public var achievedPetIds: [String]

    public init(schemaVersion: Int = currentSchemaVersion,
                pets: [String: PetProgress],
                selectedId: String,
                trainerXP: Int = 0,
                achievedPetIds: [String] = []) {
        self.schemaVersion = schemaVersion
        self.pets = pets
        self.selectedId = selectedId
        self.trainerXP = trainerXP
        self.achievedPetIds = achievedPetIds
    }

    // Backward-compat decode: v1 payload thiếu trainerXP + achievedPetIds.
    private enum CodingKeys: String, CodingKey {
        case schemaVersion, pets, selectedId, trainerXP, achievedPetIds
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        schemaVersion   = (try? c.decode(Int.self, forKey: .schemaVersion)) ?? 1
        pets            = try c.decode([String: PetProgress].self, forKey: .pets)
        selectedId      = try c.decode(String.self, forKey: .selectedId)
        trainerXP       = (try? c.decode(Int.self, forKey: .trainerXP)) ?? 0
        achievedPetIds  = (try? c.decode([String].self, forKey: .achievedPetIds)) ?? []
    }
}

/// Catalog 28 pet hợp lệ — nguồn sự thật duy nhất cho danh sách id.
public struct PetCatalog: Sendable {
    /// Tất cả 28 character id theo thứ tự hiển thị: clawd trước, rồi char00..char26.
    public static let all: [String] = ["clawd"] + (0..<27).map { String(format: "char%02d", $0) }

    /// Tên hiển thị thân thiện cho UI.
    public static func displayName(_ id: String) -> String {
        if id == "clawd" { return "Clawdy" }
        // Lấy phần số và format "Pet #XX"
        let suffix = id.dropFirst(4)          // bỏ "char"
        return "Pet #\(suffix)"
    }
}
