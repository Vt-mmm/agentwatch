// Pet unlock tree — declarative DAG of tier prerequisites.
// 28 pet chia 4 tier × 7 pet. Mỗi tier gated bởi 2 điều kiện: TrainerLv + Pet
// prerequisite (≥1 pet tier trước đạt mốc PL).
//
// Cảm hứng Stardew skill tree + Monster Hunter rank: progression rõ ràng, có
// achievement feel khi unlock tier mới.

import Foundation

public enum PetTier: Int, CaseIterable, Sendable, Comparable {
    case starter = 0
    case apprentice = 1
    case veteran = 2
    case master = 3

    public var label: String {
        switch self {
        case .starter:    return "Starter"
        case .apprentice: return "Apprentice"
        case .veteran:    return "Veteran"
        case .master:     return "Master"
        }
    }

    public var icon: String {
        switch self {
        case .starter:    return "leaf.fill"
        case .apprentice: return "flame.fill"
        case .veteran:    return "bolt.fill"
        case .master:     return "crown.fill"
        }
    }

    public static func < (lhs: PetTier, rhs: PetTier) -> Bool { lhs.rawValue < rhs.rawValue }
}

/// Yêu cầu unlock 1 pet — render thành text + boolean.
public struct UnlockRequirement: Sendable, Equatable {
    public let requiredTrainerLevel: Int
    public let requiredPriorTier: PetTier?       // nil = không cần prior tier (starter)
    public let requiredPriorPetLevel: Int        // 5 = PL≥5, 10 = mastered
    public let requiredPriorPetCount: Int        // 1 hoặc 2

    public var isStarter: Bool { requiredPriorTier == nil }

    /// Mô tả human-readable bằng tiếng Việt.
    public func description() -> String {
        guard let prior = requiredPriorTier else {
            return "Unlocked từ đầu"
        }
        let suffix = requiredPriorPetCount > 1
            ? "\(requiredPriorPetCount) pet \(prior.label)"
            : "1 pet \(prior.label)"
        let plLabel = requiredPriorPetLevel == 10 ? "đạt Lv 10 (master)" : "đạt Lv \(requiredPriorPetLevel)"
        return "Trainer Lv \(requiredTrainerLevel) + \(suffix) \(plLabel)"
    }
}

public enum PetUnlockGraph {

    /// 4 tier × 7 pet = 28. clawd là starter mặc định + chia char00-26.
    /// Phân tier dựa trên chỉ số char (đơn giản, deterministic, dễ visualize).
    private static let tierMap: [String: PetTier] = {
        var m: [String: PetTier] = ["clawd": .starter]
        for i in 0...26 {
            let id = String(format: "char%02d", i)
            switch i {
            case 0...5:   m[id] = .starter
            case 6...12:  m[id] = .apprentice
            case 13...19: m[id] = .veteran
            case 20...26: m[id] = .master
            default:      m[id] = .starter
            }
        }
        return m
    }()

    /// Yêu cầu cho mỗi tier — cùng tier dùng chung requirement.
    private static let requirementByTier: [PetTier: UnlockRequirement] = [
        .starter: UnlockRequirement(
            requiredTrainerLevel: 1,
            requiredPriorTier: nil,
            requiredPriorPetLevel: 0,
            requiredPriorPetCount: 0
        ),
        .apprentice: UnlockRequirement(
            requiredTrainerLevel: 3,
            requiredPriorTier: .starter,
            requiredPriorPetLevel: 5,
            requiredPriorPetCount: 1
        ),
        .veteran: UnlockRequirement(
            requiredTrainerLevel: 8,
            requiredPriorTier: .apprentice,
            requiredPriorPetLevel: 10,
            requiredPriorPetCount: 1
        ),
        .master: UnlockRequirement(
            requiredTrainerLevel: 15,
            requiredPriorTier: .veteran,
            requiredPriorPetLevel: 10,
            requiredPriorPetCount: 2
        )
    ]

    /// Tier của 1 pet. Default = starter cho id không khớp (safe fallback).
    public static func tier(for petId: String) -> PetTier {
        tierMap[petId] ?? .starter
    }

    /// Requirement của 1 pet (lookup qua tier).
    public static func requirement(for petId: String) -> UnlockRequirement {
        requirementByTier[tier(for: petId)] ?? requirementByTier[.starter]!
    }

    /// Check pet đã unlock chưa dựa trên state hiện tại.
    public static func isUnlocked(
        petId: String,
        pets: [String: PetProgress],
        trainerLevel: Int
    ) -> Bool {
        let req = requirement(for: petId)
        if req.isStarter { return true }
        guard trainerLevel >= req.requiredTrainerLevel else { return false }

        // Đếm prior-tier pets đạt mốc PL.
        guard let priorTier = req.requiredPriorTier else { return true }
        let qualifying = pets.values.filter {
            tier(for: $0.characterId) == priorTier && $0.level >= req.requiredPriorPetLevel
        }
        return qualifying.count >= req.requiredPriorPetCount
    }

    /// List tất cả pet id theo tier — phục vụ UI group by tier.
    public static func petIds(for tier: PetTier) -> [String] {
        tierMap.filter { $0.value == tier }.keys.sorted()
    }
}
