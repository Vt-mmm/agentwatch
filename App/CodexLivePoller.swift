// Poll-based Codex live activity tracker. Scan ~/.codex/sessions/ for rollout
// files modified trong last N minutes. Không stream JSONL (Codex CLI không có
// reliable tail trigger), poll mỗi 5s vẫn responsive cho UI Live tab.

import Foundation
import SwiftUI
import ClaudeWatchCore

/// Lightweight snapshot của Codex hoạt động gần đây — không full session detail.
struct CodexLiveSnapshot: Sendable {
    let sessions: [SessionSummary]   // last activity within window
    let totalInputTokens: Int
    let totalOutputTokens: Int
    let totalToolCalls: Int

    var sessionCount: Int { sessions.count }

    var latestSession: SessionSummary? {
        sessions.max { ($0.lastTimestamp ?? .distantPast) < ($1.lastTimestamp ?? .distantPast) }
    }
}

@Observable
@MainActor
final class CodexLivePoller {
    /// Window: chỉ count session có activity trong N giây gần đây.
    private static let activityWindowSec: TimeInterval = 300   // 5 phút

    /// Refresh interval — poll mỗi 5s vì Codex JSONL ghi liên tục.
    private static let pollIntervalSec: TimeInterval = 5

    private(set) var snapshot: CodexLiveSnapshot = CodexLiveSnapshot(
        sessions: [], totalInputTokens: 0, totalOutputTokens: 0, totalToolCalls: 0
    )

    private var timer: Timer?

    func start() {
        guard timer == nil else { return }
        refresh()
        timer = Timer.scheduledTimer(withTimeInterval: Self.pollIntervalSec, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.refresh() }
        }
    }

    func stop() {
        timer?.invalidate()
        timer = nil
    }

    private func refresh() {
        let now = Date()
        let windowStart = now.addingTimeInterval(-Self.activityWindowSec)
        let range = windowStart...now.addingTimeInterval(60)   // +60s buffer

        // Scan rollout files có mtime trong window — heavy reuse of CodexInventory.
        let sessions = CodexInventory.list(in: range)
            .filter { ($0.lastTimestamp ?? .distantPast) >= windowStart }

        let inTok = sessions.reduce(0) { $0 + $1.inputTokens }
        let outTok = sessions.reduce(0) { $0 + $1.outputTokens }
        let tools = sessions.reduce(0) { $0 + $1.toolCallCount }
        snapshot = CodexLiveSnapshot(
            sessions: sessions,
            totalInputTokens: inTok,
            totalOutputTokens: outTok,
            totalToolCalls: tools
        )
    }
}
