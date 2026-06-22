// Engine tính XP thuần túy — không phụ thuộc UI, không phụ thuộc store.
// Tất cả hàm là static, enum không có case → Sendable tự nhiên.
// Level cap: 10. Curve mềm dành cho dùng nội bộ cá nhân.

import Foundation

public enum XPEngine {

    // MARK: - Curve

    /// XP cần để thoát khỏi level n (tiến lên level n+1).
    /// Công thức: 30 × n^1.3 — pace nhanh ở level thấp, dần chậm lại.
    /// Lv1→2: 30, Lv5→6: 242, Lv9→10: 516.
    public static func xpRequired(forLevel n: Int) -> Int {
        Int(30.0 * pow(Double(max(1, n)), 1.3))
    }

    /// Tổng XP tích lũy cần để VÀO level n (tức là vượt qua Lv1..Lv(n-1)).
    /// cumulativeXP(forLevel: 1) = 0 (bắt đầu ở Lv1 với 0 XP).
    /// cumulativeXP(forLevel: 2) = 30, cumulativeXP(forLevel: 3) = 74, ...
    public static func cumulativeXP(forLevel n: Int) -> Int {
        guard n > 1 else { return 0 }
        return (1..<n).reduce(0) { $0 + xpRequired(forLevel: $1) }
    }

    /// Derive level từ tổng XP tích lũy. Cap tại 10.
    public static func level(forTotalXP totalXP: Int) -> Int {
        var lvl = 1
        var cumulative = 0
        while lvl < 10 {
            cumulative += xpRequired(forLevel: lvl)
            if totalXP < cumulative { return lvl }
            lvl += 1
        }
        return 10
    }

    /// XP progress trong level hiện tại — để vẽ bar.
    /// Trả về (current: XP đã có trong level này, needed: XP cần để lên level tiếp,
    /// level: level hiện tại).
    /// Khi level == 10, needed = xpRequired(forLevel: 10) và current = XP vượt Lv9.
    public static func progressInCurrentLevel(totalXP: Int) -> (current: Int, needed: Int, level: Int) {
        let lvl = level(forTotalXP: totalXP)
        let base = cumulativeXP(forLevel: lvl)
        let needed = xpRequired(forLevel: lvl)
        let current = min(totalXP - base, needed)
        return (current: max(0, current), needed: needed, level: lvl)
    }

    // MARK: - XP per signal

    /// XP từ 1 prompt dựa trên số sao.
    /// 0★ (follow-up ngắn) = 0, 1★=3, 2★=8, 3★=15, 4★=25, 5★=50.
    public static func xpForPrompt(stars: Int) -> Int {
        switch stars {
        case 1: return 3
        case 2: return 8
        case 3: return 15
        case 4: return 25
        case 5: return 50
        default: return 0   // 0★ hoặc ngoài range
        }
    }

    /// XP cho hoàn thành 1 session (assistant có ít nhất 1 output): +5.
    /// Penalty nếu session có outlier cost hoặc agent loop.
    public static func xpForSession(isOutlier: Bool, isAgentLoop: Bool) -> Int {
        var xp = 5  // session complete bonus
        if isAgentLoop { xp -= 10 }    // penalty agent loop ≥10 subagent
        if isOutlier   { xp -= 15 }    // penalty cost outlier >mean+2σ
        return xp
    }

    /// Streak day XP: day 1 = +15, tăng 2/ngày, cap ở +30.
    /// Ví dụ: day1=15, day2=17, day8=29, day9+=30.
    public static func xpForStreakDay(_ day: Int) -> Int {
        guard day >= 1 else { return 0 }
        return min(30, 15 + (day - 1) * 2)
    }

    // MARK: - Delta compute

    /// Kết quả split: prompt XP đi vào pet đang active, session/streak/penalty
    /// đi vào trainer (global). 2 axes progression song song.
    public struct DeltaResult: Sendable, Equatable {
        public let petXP: Int
        public let trainerXP: Int
        public init(petXP: Int, trainerXP: Int) {
            self.petXP = petXP
            self.trainerXP = trainerXP
        }
    }

    /// Tính split XP delta: pet vs trainer. Caller filter "mới" trước.
    public static func computeSplitDelta(
        newPrompts: [PromptRecord],
        newSessions: [SessionSummary],
        outlierIds: Set<String>,
        agentLoopIds: Set<String>,
        streakDay: Int
    ) -> DeltaResult {
        // Pet XP: chỉ từ prompts (active pet được "train").
        let petXP = newPrompts.reduce(0) { $0 + xpForPrompt(stars: $1.score.stars) }

        // Trainer XP: sessions + streak (penalty áp dụng tại session).
        let sessionXP = newSessions.reduce(0) {
            $0 + TrainerProgress.xpForSession(
                isOutlier: outlierIds.contains($1.id),
                isAgentLoop: agentLoopIds.contains($1.id)
            )
        }
        let streakXP = (!newSessions.isEmpty && streakDay >= 1)
            ? TrainerProgress.xpForStreakDay(streakDay) : 0

        return DeltaResult(petXP: petXP, trainerXP: sessionXP + streakXP)
    }

    /// Legacy single-int delta — giữ cho backward compat. Pet XP = prompt only,
    /// caller dùng processReload mới nên gọi computeSplitDelta.
    @available(*, deprecated, message: "Use computeSplitDelta(...) → DeltaResult")
    public static func computeDelta(
        newPrompts: [PromptRecord],
        newSessions: [SessionSummary],
        outlierIds: Set<String>,
        agentLoopIds: Set<String>,
        streakDay: Int
    ) -> Int {
        let split = computeSplitDelta(
            newPrompts: newPrompts, newSessions: newSessions,
            outlierIds: outlierIds, agentLoopIds: agentLoopIds,
            streakDay: streakDay
        )
        return split.petXP + split.trainerXP
    }
}
