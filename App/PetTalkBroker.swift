// Bridge giữa SessionWatcher/CoachingDataStore → FloatingPetController.
// Theo dõi state change, emit PetTalk khi có sự kiện đáng nói.
//
// Rule: chỉ speak khi event "fresh" (chưa nói trong session này) để pet
// không lải nhải. Variant rotate theo counter để câu thoại đa dạng.

import Foundation
import Observation
import ClaudeWatchCore

@Observable
@MainActor
final class PetTalkBroker {
    private weak var pet: FloatingPetController?

    // De-dup: nhớ session id đã chào & cost outlier đã warn để khỏi nói lại.
    private var greetedSessions: Set<String> = []
    private var warnedOutliers: Set<String> = []
    private var warnedLoops: Set<String> = []
    private var lastTotalSessions: Int = 0
    private var variant: Int = 0
    private var lastActivityAt: Date = Date()
    private var idleCheckTask: Task<Void, Never>?

    // Live tracking từ SessionWatcher.stats.
    private var liveLastToolCalls: Int = 0
    private var liveLastAgentCount: Int = 0
    private var liveLastCost: Double = 0
    private var crossedCostMarks: Set<Int> = []  // các mốc $ đã cảnh báo (cent*100)
    /// Throttle: tối thiểu 8s giữa 2 talk để pet không lải nhải. Bypass cho
    /// alert/warning (cảnh báo cần thấy ngay).
    private var lastTalkAt: Date = .distantPast
    private let throttleSec: TimeInterval = 8

    // Cost milestone — bất cứ session nào cross các mốc này → talk 1 lần.
    private static let costMilestones: [Double] = [0.5, 1, 2, 5, 10, 20, 50, 100]

    /// Bind controller cần được nói (set sau khi controller init xong).
    func attach(_ controller: FloatingPetController) {
        self.pet = controller
        // Greet 1 lần khi attach lần đầu.
        emit(.startup)
        startIdleWatcher()
    }

    /// Gọi khi CoachingDataStore reload xong. Compare snapshot mới vs state
    /// nội bộ → emit talk tương ứng.
    func observe(sessions: [SessionSummary], activeProject: String?) {
        defer { lastActivityAt = Date() }

        // Detect session mới (count tăng) — greet với tên project active.
        if sessions.count > lastTotalSessions, let proj = activeProject {
            emit(.sessionStarted(project: proj))
        }
        lastTotalSessions = sessions.count

        // Outlier mới phát hiện.
        let outliers = CoachingInsights.outlierSessions(sessions)
        for sid in outliers where !warnedOutliers.contains(sid) {
            warnedOutliers.insert(sid)
            if let s = sessions.first(where: { $0.id == sid }) {
                emit(.outlierDetected(cost: s.cost))
            }
        }

        // Agent loop mới phát hiện.
        let loops = CoachingInsights.agentLoopSessions(sessions)
        for sid in loops where !warnedLoops.contains(sid) {
            warnedLoops.insert(sid)
            if let s = sessions.first(where: { $0.id == sid }) {
                emit(.agentLoopDetected(agentCount: s.agentCount))
            }
        }
    }

    /// Emit "task done" — caller gọi từ SessionWatcher khi detect session
    /// chuyển trạng thái idle (assistant không output thêm trong N phút).
    func reportTaskDone(durationSec: Int) {
        emit(.taskDone(durationSec: durationSec))
    }

    /// Hook real-time từ SessionWatcher.stats. Detect:
    ///   - tool calls tăng ≥3 trong 1 tick → toolBurst
    ///   - agents.count tăng → subagentSpawned
    ///   - cost cross các mốc $0.5/$1/$2/$5/$10... → costThreshold
    /// Reset state nếu session id đổi (chuyển project).
    func observeLive(stats: SessionStats?) {
        guard let s = stats else { return }
        defer {
            liveLastToolCalls = s.toolCalls
            liveLastAgentCount = s.agents.count
            liveLastCost = s.cost
            lastActivityAt = Date()
        }
        // Reset milestone tracker khi session thay đổi (mới mở Claude khác).
        if s.toolCalls < liveLastToolCalls {
            // Session bị rotate hoặc reset — clear state.
            crossedCostMarks.removeAll()
            liveLastToolCalls = 0
            liveLastAgentCount = 0
            liveLastCost = 0
        }
        let toolDelta = s.toolCalls - liveLastToolCalls
        if toolDelta >= 3 {
            emit(.toolBurst(count: toolDelta), force: false)
        }
        let agentDelta = s.agents.count - liveLastAgentCount
        if agentDelta > 0 {
            emit(.subagentSpawned(total: s.agents.count), force: false)
        }
        for mark in Self.costMilestones {
            let markKey = Int(mark * 100)
            if s.cost >= mark, liveLastCost < mark,
               !crossedCostMarks.contains(markKey) {
                crossedCostMarks.insert(markKey)
                emit(.costThreshold(cost: mark), force: true)  // warning luôn show
                break
            }
        }
    }

    /// `force=true` bypass throttle — dùng cho alert/warning quan trọng.
    private func emit(_ trigger: PetTalkTrigger, force: Bool = false) {
        if !force, Date().timeIntervalSince(lastTalkAt) < throttleSec { return }
        variant += 1
        let talk = PetTalkOracle.line(for: trigger, variant: variant)
        pet?.say(talk)
        lastTalkAt = Date()
        lastActivityAt = Date()
    }

    /// Idle watcher: nếu pet im lặng >5 phút thì nói câu idle, để user biết
    /// pet vẫn alive. Chỉ trigger 1 lần mỗi idle window.
    private func startIdleWatcher() {
        idleCheckTask?.cancel()
        idleCheckTask = Task { @MainActor [weak self] in
            var lastIdleEmitAt: Date = .distantPast
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 60_000_000_000) // 1 phút check
                guard let self else { return }
                let idleSec = Date().timeIntervalSince(self.lastActivityAt)
                let mins = Int(idleSec / 60)
                if mins >= 5,
                   Date().timeIntervalSince(lastIdleEmitAt) > 600 {
                    self.emit(.idle(minutesIdle: mins))
                    lastIdleEmitAt = Date()
                }
            }
        }
    }
}
