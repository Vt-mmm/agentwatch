// Delivers native macOS notifications for significant session events:
//   - "Agent done"    when a subagent transitions live → completed
//   - "Spend update"  when session cost crosses an integer-dollar threshold

import Foundation
import UserNotifications
import ClaudeWatchCore

@Observable
@MainActor
final class NotificationService {

    // MARK: - Private State

    /// Agents we have observed in a non-completed state (live).
    private var seenLiveAgentIds: Set<String> = []

    /// Agents for which we have already posted a completion notification.
    private var seenCompletedAgentIds: Set<String> = []

    /// The highest threshold bucket crossed so far (index into `thresholdLadder`).
    private var lastCostBucket: Int = 0

    // MARK: - Constants

    /// Ascending dollar thresholds. Largest value ≤ current cost is the "bucket".
    private static let thresholdLadder: [Int] = [1, 2, 5, 10, 25, 50, 100, 250, 500, 1000]

    // MARK: - Init

    init() {
        requestAuthorization()
    }

    // MARK: - Public

    /// Call this every time SessionStats changes (e.g. from .onChange in the App scene).
    func update(with stats: SessionStats?) {
        guard let stats else { return }

        processAgents(stats.agents)
        processCost(stats.cost)
    }

    // MARK: - Streak risk (v0.6.0)

    /// Day key (YYYYMMDD) when we last posted streak-risk noti — avoid spam multiple/day.
    private var lastStreakRiskDayKey: String = ""

    /// Check streak risk: nếu streak > 0 + stale today + sau giờ user-configured,
    /// và chưa post hôm nay → fire 1 notification. opt-in only (default OFF).
    /// - Parameters:
    ///   - streakDay: số ngày streak hiện tại
    ///   - isStale: lastActiveDayStart < startOfToday
    ///   - notifyHour: giờ user muốn nhắc (mặc định 18)
    func checkStreakRisk(streakDay: Int, isStale: Bool, notifyHour: Int = 18) {
        guard streakDay > 0, isStale else { return }
        let cal = Calendar.current
        let now = Date()
        let hour = cal.component(.hour, from: now)
        guard hour >= notifyHour else { return }

        let key = streakDayKey(now)
        guard key != lastStreakRiskDayKey else { return }
        lastStreakRiskDayKey = key

        post(
            title: "🔥 Streak \(streakDay) ngày sắp mất",
            subtitle: nil,
            body: "Hôm nay anh chưa có session — gửi 1 prompt để giữ streak.",
            identifier: "streak-risk-\(key)"
        )
    }

    private func streakDayKey(_ date: Date) -> String {
        let f = DateFormatter()
        f.dateFormat = "yyyyMMdd"
        f.timeZone = .current
        return f.string(from: date)
    }

    // MARK: - Private: Agent Notifications

    private func processAgents(_ agents: [AgentSpawn]) {
        for agent in agents {
            if !agent.completed {
                // Track it as "live" so we can fire when it completes.
                seenLiveAgentIds.insert(agent.id)
            } else if seenLiveAgentIds.contains(agent.id),
                      !seenCompletedAgentIds.contains(agent.id) {
                // Seen live before, now completed — fire once.
                postAgentDone(agent)
                seenCompletedAgentIds.insert(agent.id)
                seenLiveAgentIds.remove(agent.id)
            }
            // Agents that arrive already-completed on first observation:
            // never entered seenLiveAgentIds, so the condition above is false — no notification.
        }
    }

    private func postAgentDone(_ agent: AgentSpawn) {
        let rawBody = agent.description.isEmpty ? "(no description)" : agent.description
        let body = rawBody.count > 120
            ? String(rawBody.prefix(120))
            : rawBody

        post(
            title: "Agent done",
            subtitle: agent.subagentType,
            body: body,
            identifier: "agent-\(agent.id)"
        )
    }

    // MARK: - Private: Cost Notifications

    private func processCost(_ cost: Double) {
        let newBucket = Self.bucket(for: cost)
        guard newBucket > lastCostBucket else { return }

        // Fire one notification per threshold crossed (handles skipped rungs).
        for bucketIndex in (lastCostBucket + 1)...newBucket {
            let threshold = Self.thresholdLadder[bucketIndex - 1]
            post(
                title: "Spend update",
                subtitle: nil,
                body: "Session crossed $\(threshold)",
                identifier: "cost-\(threshold)"
            )
        }
        lastCostBucket = newBucket
    }

    /// Returns 0 when cost < first threshold, otherwise the count of thresholds crossed.
    private static func bucket(for cost: Double) -> Int {
        var crossed = 0
        for threshold in thresholdLadder where Double(threshold) <= cost {
            crossed += 1
        }
        return crossed
    }

    // MARK: - Private: Notification Dispatch

    private func post(title: String, subtitle: String?, body: String, identifier: String) {
        let content = UNMutableNotificationContent()
        content.title = title
        if let subtitle {
            content.subtitle = subtitle
        }
        content.body = body
        content.sound = .default

        let request = UNNotificationRequest(
            identifier: identifier,
            content: content,
            trigger: nil   // deliver immediately
        )

        UNUserNotificationCenter.current().add(request) { error in
            if let error {
                // Silent log — never surface notification errors to the user UI.
                print("[NotificationService] Failed to post '\(identifier)': \(error.localizedDescription)")
            }
        }
    }

    // MARK: - Private: Authorization

    private func requestAuthorization() {
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { granted, error in
            if let error {
                print("[NotificationService] Authorization error: \(error.localizedDescription)")
            } else if !granted {
                print("[NotificationService] Notification permission not granted.")
            }
        }
    }
}
