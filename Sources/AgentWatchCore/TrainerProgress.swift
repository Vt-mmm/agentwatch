// Trainer Level — progression GLOBAL, riêng so với pet level từng con.
// Cảm hứng Pokémon GO: Trainer Lv mở khoá pet tier mới, trong khi Pet Lv là
// progression cá nhân từng con. 2 axes parallel.
//
// XP source: session complete, streak day, achievement (unlock pet) — KHÔNG
// nhận XP từ prompt. Prompt XP đi vào pet đang active (xem XPEngine).
//
// Curve slower hơn pet (50 × n^1.4 vs 30 × n^1.3) — trainer cần thời gian.
// Cap 30 levels — đủ chỗ cho long-tail progression.

import Foundation

public enum TrainerProgress {

    /// Cap level — trainer dài hơn pet (30 vs 10).
    public static let maxLevel: Int = 30

    /// XP cần để thoát level n. Lv1→2 = 50, Lv5→6 = 528, Lv15→16 = 2300.
    public static func xpRequired(forLevel n: Int) -> Int {
        Int(50.0 * pow(Double(max(1, n)), 1.4))
    }

    /// Tổng XP cumulative để VÀO level n.
    public static func cumulativeXP(forLevel n: Int) -> Int {
        guard n > 1 else { return 0 }
        return (1..<n).reduce(0) { $0 + xpRequired(forLevel: $1) }
    }

    /// Derive trainer level từ tổng XP. Cap tại maxLevel.
    public static func level(forTotalXP totalXP: Int) -> Int {
        var lvl = 1
        var cumulative = 0
        while lvl < maxLevel {
            cumulative += xpRequired(forLevel: lvl)
            if totalXP < cumulative { return lvl }
            lvl += 1
        }
        return maxLevel
    }

    /// Progress trong level hiện tại — cho XP bar.
    public static func progressInCurrentLevel(totalXP: Int) -> (current: Int, needed: Int, level: Int) {
        let lvl = level(forTotalXP: totalXP)
        let base = cumulativeXP(forLevel: lvl)
        let needed = xpRequired(forLevel: lvl)
        let current = min(totalXP - base, needed)
        return (current: max(0, current), needed: needed, level: lvl)
    }

    // MARK: - XP per signal (trainer-only signals)

    /// Session complete: +5 base, penalty nếu outlier/loop.
    /// Identical to pet's xpForSession nhưng trainer NHẬN, KHÔNG phải pet.
    public static func xpForSession(isOutlier: Bool, isAgentLoop: Bool) -> Int {
        var xp = 5
        if isAgentLoop { xp -= 10 }
        if isOutlier   { xp -= 15 }
        return xp
    }

    /// Streak XP — same curve như XPEngine.xpForStreakDay nhưng goes to trainer.
    public static func xpForStreakDay(_ day: Int) -> Int {
        guard day >= 1 else { return 0 }
        return min(30, 15 + (day - 1) * 2)
    }

    /// Achievement bonus khi pet maxed out (PL=10) hoặc unlock pet mới.
    public static let xpPerAchievement: Int = 50
}
