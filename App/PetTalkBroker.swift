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

    private func emit(_ trigger: PetTalkTrigger) {
        variant += 1
        let talk = PetTalkOracle.line(for: trigger, variant: variant)
        pet?.say(talk)
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
