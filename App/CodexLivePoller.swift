// Poll-based Codex live activity tracker. Scan ~/.codex/sessions/ for rollout
// files modified trong last N minutes. Không stream JSONL (Codex CLI không có
// reliable tail trigger), poll mỗi 5s vẫn responsive cho UI Live tab.

import Foundation
import SwiftUI
import ClaudeWatchCore

/// Lightweight snapshot của Codex hoạt động gần đây — không full session detail.
struct CodexLiveSnapshot: Sendable, Equatable {
    let sessions: [SessionSummary]   // last activity within window
    let totalInputTokens: Int
    let totalOutputTokens: Int
    let totalCacheReadTokens: Int
    let totalCacheWriteTokens: Int
    let totalToolCalls: Int
    let totalCost: Double

    var sessionCount: Int { sessions.count }
    var totalTokens: Int {
        totalInputTokens + totalOutputTokens + totalCacheReadTokens + totalCacheWriteTokens
    }

    var latestSession: SessionSummary? {
        sessions.max { ($0.lastTimestamp ?? .distantPast) < ($1.lastTimestamp ?? .distantPast) }
    }
}

@Observable
@MainActor
final class CodexLivePoller {
    /// Window: chỉ count session có activity trong N giây gần đây.
    nonisolated private static let activityWindowSec: TimeInterval = 300   // 5 phút

    /// Refresh interval — poll vừa đủ realtime, tránh parse/poll quá dày trên máy team.
    nonisolated private static let pollIntervalSec: TimeInterval = 8

    private(set) var snapshot: CodexLiveSnapshot = CodexLiveSnapshot(
        sessions: [], totalInputTokens: 0, totalOutputTokens: 0,
        totalCacheReadTokens: 0, totalCacheWriteTokens: 0,
        totalToolCalls: 0, totalCost: 0
    )

    private var timer: Timer?
    private var refreshTask: Task<Void, Never>?
    private var cache: [String: SummaryCacheEntry] = [:]

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
        refreshTask?.cancel()
        refreshTask = nil
    }

    private func refresh() {
        guard refreshTask == nil else { return }
        let cacheSnapshot = cache
        refreshTask = Task.detached(priority: .utility) { [cacheSnapshot] in
            let result = Self.scanCodexLive(cache: cacheSnapshot)
            await MainActor.run { [weak self] in
                guard let self else { return }
                self.cache = result.cache
                if self.snapshot != result.snapshot {
                    self.snapshot = result.snapshot
                }
                self.refreshTask = nil
            }
        }
    }

    private struct SummaryCacheEntry: Sendable {
        let mtime: Date
        let size: Int
        let summary: SessionSummary?
        let lastAccess: Date
    }

    nonisolated private static func scanCodexLive(
        cache: [String: SummaryCacheEntry]
    ) -> (snapshot: CodexLiveSnapshot, cache: [String: SummaryCacheEntry]) {
        let now = Date()
        let windowStart = now.addingTimeInterval(-activityWindowSec)
        let range = windowStart...now.addingTimeInterval(60)
        var nextCache = cache
        var sessions: [SessionSummary] = []
        let root = CodexInventory.defaultRoot
        let fm = FileManager.default

        guard fm.fileExists(atPath: root),
              let enumerator = fm.enumerator(
                at: URL(fileURLWithPath: root),
                includingPropertiesForKeys: [
                    .contentModificationDateKey,
                    .fileSizeKey,
                    .isRegularFileKey
                ]
              ) else {
            return (.empty, prune(nextCache, now: now))
        }

        for case let file as URL in enumerator where file.pathExtension == "jsonl" {
            guard let values = try? file.resourceValues(forKeys: [
                .contentModificationDateKey,
                .fileSizeKey,
                .isRegularFileKey
            ]),
            values.isRegularFile != false,
            let mtime = values.contentModificationDate,
            mtime >= windowStart else {
                continue
            }

            let key = file.path
            let size = values.fileSize ?? 0
            let summary: SessionSummary?
            if let hit = nextCache[key],
               hit.mtime == mtime,
               hit.size == size {
                summary = hit.summary
                nextCache[key] = SummaryCacheEntry(
                    mtime: hit.mtime, size: hit.size,
                    summary: hit.summary, lastAccess: now)
            } else {
                summary = CodexJsonlParser.summarize(file: file, range: range)
                nextCache[key] = SummaryCacheEntry(
                    mtime: mtime, size: size, summary: summary, lastAccess: now)
            }

            guard let summary,
                  (summary.lastTimestamp ?? .distantPast) >= windowStart else {
                continue
            }
            sessions.append(summary)
        }

        sessions.sort {
            ($0.lastTimestamp ?? .distantPast) > ($1.lastTimestamp ?? .distantPast)
        }

        let snapshot = CodexLiveSnapshot(
            sessions: sessions,
            totalInputTokens: sessions.reduce(0) { $0 + $1.inputTokens },
            totalOutputTokens: sessions.reduce(0) { $0 + $1.outputTokens },
            totalCacheReadTokens: sessions.reduce(0) { $0 + $1.cacheReadTokens },
            totalCacheWriteTokens: sessions.reduce(0) { $0 + $1.cacheWriteTokens },
            totalToolCalls: sessions.reduce(0) { $0 + $1.toolCallCount },
            totalCost: sessions.reduce(0) { $0 + $1.cost }
        )
        return (snapshot, prune(nextCache, now: now))
    }

    nonisolated private static func prune(
        _ cache: [String: SummaryCacheEntry],
        now: Date
    ) -> [String: SummaryCacheEntry] {
        let fresh = cache.filter { now.timeIntervalSince($0.value.lastAccess) < 600 }
        guard fresh.count > 300 else { return fresh }
        let keepKeys = Set(fresh
            .sorted { $0.value.lastAccess > $1.value.lastAccess }
            .prefix(300)
            .map(\.key))
        return fresh.filter { keepKeys.contains($0.key) }
    }
}

private extension CodexLiveSnapshot {
    static let empty = CodexLiveSnapshot(
        sessions: [],
        totalInputTokens: 0,
        totalOutputTokens: 0,
        totalCacheReadTokens: 0,
        totalCacheWriteTokens: 0,
        totalToolCalls: 0,
        totalCost: 0
    )
}

/// Lightweight snapshot của PiAgent activity gần đây. Đây là trục live cho
/// task/session name: không parse full history, chỉ đụng file có mtime mới.
struct PiAgentLiveSnapshot: Sendable, Equatable {
    let sessions: [SessionSummary]
    let totalInputTokens: Int
    let totalOutputTokens: Int
    let totalReasoningTokens: Int
    let totalCacheReadTokens: Int
    let totalCacheWriteTokens: Int
    let totalToolCalls: Int
    let totalCost: Double

    var sessionCount: Int { sessions.count }
    var totalTokens: Int {
        totalInputTokens + totalOutputTokens + totalReasoningTokens
            + totalCacheReadTokens + totalCacheWriteTokens
    }

    var latestSession: SessionSummary? {
        sessions.max { ($0.lastTimestamp ?? .distantPast) < ($1.lastTimestamp ?? .distantPast) }
    }

    var namedTaskCount: Int {
        sessions.filter(\.hasTaskSessionTitle).count
    }
}

@Observable
@MainActor
final class PiAgentLivePoller {
    nonisolated private static let activityWindowSec: TimeInterval = 300
    nonisolated private static let pollIntervalSec: TimeInterval = 8

    private(set) var snapshot: PiAgentLiveSnapshot = .empty

    private var timer: Timer?
    private var refreshTask: Task<Void, Never>?
    private var cache: [String: SummaryCacheEntry] = [:]

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
        refreshTask?.cancel()
        refreshTask = nil
    }

    private func refresh() {
        guard refreshTask == nil else { return }
        let cacheSnapshot = cache
        refreshTask = Task.detached(priority: .utility) { [cacheSnapshot] in
            let result = Self.scanPiAgentLive(cache: cacheSnapshot)
            await MainActor.run { [weak self] in
                guard let self else { return }
                self.cache = result.cache
                if self.snapshot != result.snapshot {
                    self.snapshot = result.snapshot
                }
                self.refreshTask = nil
            }
        }
    }

    private struct SummaryCacheEntry: Sendable {
        let mtime: Date
        let size: Int
        let summary: SessionSummary?
        let lastAccess: Date
    }

    nonisolated private static func scanPiAgentLive(
        cache: [String: SummaryCacheEntry]
    ) -> (snapshot: PiAgentLiveSnapshot, cache: [String: SummaryCacheEntry]) {
        let now = Date()
        let windowStart = now.addingTimeInterval(-activityWindowSec)
        let range = windowStart...now.addingTimeInterval(60)
        var nextCache = cache
        var sessions: [SessionSummary] = []
        let root = PiAgentInventory.defaultRoot
        let fm = FileManager.default

        guard fm.fileExists(atPath: root),
              let enumerator = fm.enumerator(
                at: URL(fileURLWithPath: root),
                includingPropertiesForKeys: [
                    .contentModificationDateKey,
                    .fileSizeKey,
                    .isRegularFileKey
                ]
              ) else {
            return (.empty, prune(nextCache, now: now))
        }

        for case let file as URL in enumerator where file.pathExtension == "jsonl" {
            guard !file.pathComponents.contains("subagent"),
                  let values = try? file.resourceValues(forKeys: [
                    .contentModificationDateKey,
                    .fileSizeKey,
                    .isRegularFileKey
                  ]),
                  values.isRegularFile != false,
                  let mtime = values.contentModificationDate,
                  mtime >= windowStart else {
                continue
            }

            let key = file.path
            let size = values.fileSize ?? 0
            let summary: SessionSummary?
            if let hit = nextCache[key],
               hit.mtime == mtime,
               hit.size == size {
                summary = hit.summary
                nextCache[key] = SummaryCacheEntry(
                    mtime: hit.mtime, size: hit.size,
                    summary: hit.summary, lastAccess: now)
            } else {
                summary = PiAgentJsonlParser.summarize(file: file, range: range)
                nextCache[key] = SummaryCacheEntry(
                    mtime: mtime, size: size, summary: summary, lastAccess: now)
            }

            guard let summary,
                  (summary.lastTimestamp ?? .distantPast) >= windowStart else {
                continue
            }
            sessions.append(summary)
        }

        sessions.sort {
            ($0.lastTimestamp ?? .distantPast) > ($1.lastTimestamp ?? .distantPast)
        }

        let snapshot = PiAgentLiveSnapshot(
            sessions: sessions,
            totalInputTokens: sessions.reduce(0) { $0 + $1.inputTokens },
            totalOutputTokens: sessions.reduce(0) { $0 + $1.outputTokens },
            totalReasoningTokens: sessions.reduce(0) { $0 + $1.reasoningTokens },
            totalCacheReadTokens: sessions.reduce(0) { $0 + $1.cacheReadTokens },
            totalCacheWriteTokens: sessions.reduce(0) { $0 + $1.cacheWriteTokens },
            totalToolCalls: sessions.reduce(0) { $0 + $1.toolCallCount },
            totalCost: sessions.reduce(0) { $0 + $1.cost }
        )
        return (snapshot, prune(nextCache, now: now))
    }

    nonisolated private static func prune(
        _ cache: [String: SummaryCacheEntry],
        now: Date
    ) -> [String: SummaryCacheEntry] {
        let fresh = cache.filter { now.timeIntervalSince($0.value.lastAccess) < 600 }
        guard fresh.count > 300 else { return fresh }
        let keepKeys = Set(fresh
            .sorted { $0.value.lastAccess > $1.value.lastAccess }
            .prefix(300)
            .map(\.key))
        return fresh.filter { keepKeys.contains($0.key) }
    }
}

private extension PiAgentLiveSnapshot {
    static let empty = PiAgentLiveSnapshot(
        sessions: [],
        totalInputTokens: 0,
        totalOutputTokens: 0,
        totalReasoningTokens: 0,
        totalCacheReadTokens: 0,
        totalCacheWriteTokens: 0,
        totalToolCalls: 0,
        totalCost: 0
    )
}
