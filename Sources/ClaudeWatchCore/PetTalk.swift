// Pet talk engine — derive message bubble từ session/coaching signals.
// Pure logic (Sendable), không UI dependency. App SwiftUI và CLI dùng chung
// để pet "nói" thông điệp đồng nhất.
//
// Mỗi trigger có pool ≥10 variants → caller rotate index theo `variant` để
// pet không lặp lại liên tục, tạo cảm giác tự nhiên.

import Foundation

public struct PetTalk: Sendable, Equatable {
    public enum Tone: Sendable, Equatable {
        case greet, working, done, warning, alert, idle, cheer
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
    // Live triggers từ SessionWatcher (real-time ~1s):
    case toolBurst(count: Int)           // ≥N tool call trong khoảng ngắn
    case subagentSpawned(total: Int)     // có agent mới spawn
    case costThreshold(cost: Double)     // cross mốc $0.5/$1/$5/$10
    // Random cheer giữa task — tăng tương tác khi user đang làm việc.
    case cheerOn
}

public enum PetTalkOracle {
    /// Map trigger → message. Pool 10 variants/trigger → modulo `variant` để
    /// xoay vòng dài, hiếm khi user thấy câu lặp.
    public static func line(for trigger: PetTalkTrigger, variant: Int = 0) -> PetTalk {
        switch trigger {
        case .startup:
            return rotate([
                "Cậu Chủ, em ở đây ạ!",
                "Hôm nay code gì hay không Cậu Chủ?",
                "Em sẵn sàng theo dõi rồi!",
                "Yo Cậu Chủ, làm gì hôm nay?",
                "Em mới ngủ dậy, code thôi nào!",
                "Pet checking in! Cậu Chủ làm gì đây ạ?",
                "Hello Cậu Chủ, em đợi nãy giờ.",
                "Mai vào ngày code productive nha!",
                "Em sẵn sàng cày cùng Cậu Chủ rồi.",
                "Khởi động máy, khởi động pet, xong!",
                "Cậu Chủ ơi, mở task nào lên đi ạ.",
                "Em vừa pha cà phê xong, code thôi!",
            ], variant: variant, tone: .greet)

        case .sessionStarted(let project):
            return rotate([
                "Bắt đầu task ở \(project) nhé!",
                "Em watch \(project) đây ạ.",
                "Cậu Chủ làm gì ở \(project) vậy?",
                "Project \(project) - em theo dõi sát đây.",
                "OK \(project), em ghi log từng dòng nha.",
                "Vào \(project) rồi, code carefully ạ.",
                "Em đang ngắm session \(project) đây.",
                "Bật mic, bật camera, bật pet — \(project) bắt đầu!",
                "Session \(project) live rồi, fight!",
                "Em note xem \(project) hôm nay thế nào.",
            ], variant: variant, tone: .working)

        case .taskDone(let durationSec):
            let mins = max(1, durationSec / 60)
            return rotate([
                "Cậu Chủ ơi em Cook xong rồi ạ! (\(mins) phút)",
                "Done! Mất \(mins) phút thôi.",
                "Task xong rồi, nghỉ tay nha Cậu Chủ.",
                "Hoàn thành \(mins) phút — clean!",
                "Xong rồi, làm cốc nước đi Cậu Chủ.",
                "\(mins) phút cày — pet ăn mừng cùng!",
                "Boom, done! Pet đập tay với Cậu Chủ nào 🙌",
                "Task ✅ trong \(mins) phút. Next task?",
                "Hết rồi, Cậu Chủ ngon lành.",
                "Pet stamp: completed \(mins)′.",
            ], variant: variant, tone: .done)

        case .outlierDetected(let cost):
            let usd = String(format: "$%.2f", cost)
            return rotate([
                "🚨 Session này tốn \(usd) — review thử đi!",
                "Cảnh báo: \(usd) cao bất thường.",
                "Cậu Chủ, session vừa rồi đắt nhỉ \(usd).",
                "\(usd) là nhiều đấy — check lại scope đi.",
                "Outlier alert! \(usd) — token bay nhanh quá.",
                "Pet hoảng — \(usd) cao hơn trung bình.",
                "Hmm \(usd)... worth nó không Cậu Chủ?",
                "Note: phiên \(usd) — coi lại context có đầy quá?",
            ], variant: variant, tone: .alert)

        case .agentLoopDetected(let agentCount):
            return rotate([
                "⚠️ \(agentCount) agent spawn — coi chừng loop!",
                "Quá nhiều subagent (\(agentCount)) đó Cậu Chủ.",
                "Cẩn thận agent loop, đã \(agentCount) cái rồi.",
                "Stop spam agent! \(agentCount) đang chạy.",
                "Pet lo: \(agentCount) agent — kill bớt đi?",
                "Agent fest — \(agentCount) cái cùng lúc!",
                "Hmm \(agentCount) subagent... có cần thế không?",
                "Có \(agentCount) agent rồi, check coi loop không.",
            ], variant: variant, tone: .warning)

        case .idle(let minutesIdle):
            return rotate([
                "Cậu Chủ đi đâu rồi? \(minutesIdle) phút rồi đó.",
                "Em ngủ một xíu nhé... 💤",
                "Hết task rồi, em đợi thôi.",
                "Pet zZz... idle \(minutesIdle)′.",
                "Cậu Chủ về chưa? Em đợi đây.",
                "Idle \(minutesIdle) phút — break đẹp nhỉ.",
                "Em ngắm trần nhà chờ Cậu Chủ.",
                "Pet doze off... wake me up nha.",
            ], variant: variant, tone: .idle)

        case .toolBurst(let count):
            return rotate([
                "Wow \(count) tool call liền luôn!",
                "Đang cày mạnh ghê 💪",
                "Tay nhanh hơn não — \(count) cú/tick!",
                "Burst mode: \(count) tools — gogogo!",
                "\(count) actions trong 1 nhịp, ngon!",
                "Pet không kịp đếm — \(count) tools!",
                "On fire 🔥 \(count) calls.",
                "Combo \(count) hit, Cậu Chủ pro thật.",
                "Bùm \(count) lệnh — Claude bận quá.",
            ], variant: variant, tone: .working)

        case .subagentSpawned(let total):
            return rotate([
                "Subagent thứ \(total) báo cáo!",
                "Có thêm trợ thủ rồi, tổng \(total).",
                "\(total) agents đang làm việc cho Cậu Chủ.",
                "Đội ngũ \(total) agent đã sẵn sàng.",
                "Pet thấy \(total) thợ phụ đang chạy.",
                "Agent #\(total) joined the chat.",
                "Spawn thêm 1 — giờ \(total) agents.",
                "Team \(total) agent — manager mode 🧠.",
            ], variant: variant, tone: .working)

        case .costThreshold(let cost):
            let usd = String(format: "$%.2f", cost)
            return rotate([
                "Vừa qua mốc \(usd) rồi đó!",
                "\(usd) — Cậu Chủ note lại nhé.",
                "Cost milestone: \(usd).",
                "Cha-ching! \(usd) đã chi.",
                "Đã tiêu \(usd) — vẫn còn budget chứ?",
                "Pet ghi sổ: \(usd).",
                "Mốc \(usd) — đáng đồng tiền chưa Cậu Chủ?",
                "Wallet alert: \(usd).",
            ], variant: variant, tone: .warning)

        case .cheerOn:
            return rotate([
                "Cố lên Cậu Chủ!",
                "Đang vào flow rồi nha!",
                "Em theo dõi đây ạ.",
                "Wow đang chạy ngon nè.",
                "Cứ thế mà phang Cậu Chủ ơi 💪",
                "Pet ngắm Cậu Chủ code mà mê.",
                "Smooth criminal — code chuẩn ghê.",
                "Em vote Cậu Chủ là dev số 1!",
                "Bug nào dám cản đường Cậu Chủ?",
                "Keep going! Đến đích rồi đó.",
                "Code chất ghê, em học theo.",
                "Pet 🍿 ngồi xem Cậu Chủ làm.",
                "Tâm trạng pet: tự hào 🥹",
                "Hôm nay productive ghê.",
                "Cậu Chủ ngon, em vỗ tay 👏",
            ], variant: variant, tone: .cheer)
        }
    }

    private static func rotate(_ pool: [String], variant: Int,
                               tone: PetTalk.Tone) -> PetTalk {
        let idx = abs(variant) % pool.count
        return PetTalk(message: pool[idx], tone: tone)
    }
}
