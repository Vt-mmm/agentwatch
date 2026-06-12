// Pet talk engine — derive message bubble từ session/coaching signals.
// Pure logic (Sendable), không UI dependency. App SwiftUI và CLI dùng chung
// để pet "nói" thông điệp đồng nhất.

import Foundation

public struct PetTalk: Sendable, Equatable {
    public enum Tone: Sendable, Equatable {
        case greet, working, done, warning, alert, idle
    }

    public let message: String
    public let tone: Tone

    public init(message: String, tone: Tone) {
        self.message = message
        self.tone = tone
    }
}

/// Sự kiện trigger pet speak. Caller emit khi SessionWatcher detect change.
public enum PetTalkTrigger: Sendable, Equatable {
    case sessionStarted(project: String)
    case taskDone(durationSec: Int)
    case outlierDetected(cost: Double)
    case agentLoopDetected(agentCount: Int)
    case idle(minutesIdle: Int)
    case startup
}

public enum PetTalkOracle {
    /// Map trigger → message. Sử dụng pool nhỏ để pet không lặp khô khốc;
    /// caller có thể rotate index theo `variant` (0..<count).
    public static func line(for trigger: PetTalkTrigger, variant: Int = 0) -> PetTalk {
        switch trigger {
        case .startup:
            return rotate([
                "Cậu Chủ, em ở đây ạ!",
                "Hôm nay code gì hay không Cậu Chủ?",
                "Em sẵn sàng theo dõi rồi!",
            ], variant: variant, tone: .greet)

        case .sessionStarted(let project):
            return rotate([
                "Bắt đầu task ở \(project) nhé!",
                "Em watch \(project) đây ạ.",
                "Cậu Chủ làm gì ở \(project) vậy?",
            ], variant: variant, tone: .working)

        case .taskDone(let durationSec):
            let mins = max(1, durationSec / 60)
            return rotate([
                "Cậu Chủ ơi em Cook xong rồi ạ! (\(mins) phút)",
                "Done! Mất \(mins) phút thôi.",
                "Task xong rồi, nghỉ tay nha Cậu Chủ.",
            ], variant: variant, tone: .done)

        case .outlierDetected(let cost):
            let usd = String(format: "$%.2f", cost)
            return rotate([
                "🚨 Session này tốn \(usd) — review thử đi!",
                "Cảnh báo: \(usd) cao bất thường.",
                "Cậu Chủ, session vừa rồi đắt nhỉ \(usd).",
            ], variant: variant, tone: .alert)

        case .agentLoopDetected(let agentCount):
            return rotate([
                "⚠️ \(agentCount) agent spawn — coi chừng loop!",
                "Quá nhiều subagent (\(agentCount)) đó Cậu Chủ.",
                "Cẩn thận agent loop, đã \(agentCount) cái rồi.",
            ], variant: variant, tone: .warning)

        case .idle(let minutesIdle):
            return rotate([
                "Cậu Chủ đi đâu rồi? \(minutesIdle) phút rồi đó.",
                "Em ngủ một xíu nhé... 💤",
                "Hết task rồi, em đợi thôi.",
            ], variant: variant, tone: .idle)
        }
    }

    private static func rotate(_ pool: [String], variant: Int,
                               tone: PetTalk.Tone) -> PetTalk {
        let idx = abs(variant) % pool.count
        return PetTalk(message: pool[idx], tone: tone)
    }
}
