// One-shot Codex/PiAgent recent-log snapshot for the Sessions tab.
// Không poll nền: Agent Watch là audit log viewer, chỉ scan khi user bấm
// refresh/export. App-open governance log chạy riêng trong SupervisorLockStore.

import Foundation
import SwiftUI
import ClaudeWatchCore

/// Lightweight snapshot của Codex log gần đây — không full session detail.
struct CodexLiveSnapshot: Sendable, Equatable {
    let sessions: [SessionSummary]
    let totalInputTokens: Int
    let totalOutputTokens: Int
    let totalCacheReadTokens: Int
    let totalCacheWriteTokens: Int
    let totalToolCalls: Int
    let totalCost: Double

    var sessionCount: Int { sessions.count }
    var totalReasoningTokens: Int {
        sessions.reduce(0) { $0 + $1.reasoningTokens }
    }
    var totalTokens: Int {
        sessions.reduce(0) { $0 + $1.totalTokens }
    }
    var reportedCost: Double {
        sessions.filter { $0.costBasis == .reported }.reduce(0) { $0 + $1.cost }
    }
    var estimatedCost: Double {
        sessions.filter { $0.costBasis == .estimated }.reduce(0) { $0 + $1.cost }
    }

    var latestSession: SessionSummary? {
        sessions.max { ($0.lastTimestamp ?? .distantPast) < ($1.lastTimestamp ?? .distantPast) }
    }
}

@Observable
@MainActor
final class CodexLivePoller {
    /// Chỉ parse một số file mới nhất để Sessions tab nhẹ, không thành realtime scanner.
    nonisolated private static let maxCandidateFiles = 60
    nonisolated private static let maxRecentSessions = 12

    private(set) var snapshot: CodexLiveSnapshot = CodexLiveSnapshot(
        sessions: [], totalInputTokens: 0, totalOutputTokens: 0,
        totalCacheReadTokens: 0, totalCacheWriteTokens: 0,
        totalToolCalls: 0, totalCost: 0
    )

    private var refreshTask: Task<Void, Never>?
    private var cache: [String: SummaryCacheEntry] = [:]

    func refreshOnce() {
        refresh()
    }

    private func refresh() {
        guard refreshTask == nil else { return }
        let cacheSnapshot = cache
        refreshTask = Task.detached(priority: .utility) { [cacheSnapshot] in
            let result = Self.scanCodexSnapshot(cache: cacheSnapshot)
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

    nonisolated private static func scanCodexSnapshot(
        cache: [String: SummaryCacheEntry]
    ) -> (snapshot: CodexLiveSnapshot, cache: [String: SummaryCacheEntry]) {
        let now = Date()
        let range = Date.distantPast...now.addingTimeInterval(60)
        var nextCache = cache
        var sessions: [SessionSummary] = []
        let candidates = recentJsonlFiles(
            roots: [CodexInventory.defaultRoot, CodexInventory.defaultArchivedRoot],
            skipSubagentPaths: false,
            limit: maxCandidateFiles
        )
        guard !candidates.isEmpty else {
            return (.empty, prune(nextCache, now: now))
        }

        for candidate in candidates {
            let key = candidate.url.path
            let summary: SessionSummary?
            if let hit = nextCache[key],
               hit.mtime == candidate.mtime,
               hit.size == candidate.size {
                summary = hit.summary
                nextCache[key] = SummaryCacheEntry(
                    mtime: hit.mtime, size: hit.size,
                    summary: hit.summary, lastAccess: now)
            } else {
                summary = CodexJsonlParser.summarize(file: candidate.url, range: range)
                nextCache[key] = SummaryCacheEntry(
                    mtime: candidate.mtime, size: candidate.size,
                    summary: summary, lastAccess: now)
            }

            if let summary { sessions.append(summary) }
        }

        sessions = Array(sessions
            .sorted { ($0.lastTimestamp ?? .distantPast) > ($1.lastTimestamp ?? .distantPast) }
            .prefix(maxRecentSessions))

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

/// Lightweight snapshot của PiAgent log gần đây. Đây là trục check
/// task/session name: không parse full history, chỉ đọc vài file mới nhất.
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
        sessions.reduce(0) { $0 + $1.totalTokens }
    }
    var reportedCost: Double {
        sessions.filter { $0.costBasis == .reported }.reduce(0) { $0 + $1.cost }
    }
    var estimatedCost: Double {
        sessions.filter { $0.costBasis == .estimated }.reduce(0) { $0 + $1.cost }
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
    nonisolated private static let maxCandidateFiles = 60
    nonisolated private static let maxRecentSessions = 12

    private(set) var snapshot: PiAgentLiveSnapshot = .empty

    private var refreshTask: Task<Void, Never>?
    private var cache: [String: SummaryCacheEntry] = [:]

    func refreshOnce() {
        refresh()
    }

    private func refresh() {
        guard refreshTask == nil else { return }
        let cacheSnapshot = cache
        refreshTask = Task.detached(priority: .utility) { [cacheSnapshot] in
            let result = Self.scanPiAgentSnapshot(cache: cacheSnapshot)
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

    nonisolated private static func scanPiAgentSnapshot(
        cache: [String: SummaryCacheEntry]
    ) -> (snapshot: PiAgentLiveSnapshot, cache: [String: SummaryCacheEntry]) {
        let now = Date()
        let range = Date.distantPast...now.addingTimeInterval(60)
        var nextCache = cache
        var sessions: [SessionSummary] = []
        let candidates = recentJsonlFiles(
            roots: [PiAgentInventory.defaultRoot],
            skipSubagentPaths: true,
            limit: maxCandidateFiles
        )
        guard !candidates.isEmpty else {
            return (.empty, prune(nextCache, now: now))
        }

        for candidate in candidates {
            let key = candidate.url.path
            let summary: SessionSummary?
            if let hit = nextCache[key],
               hit.mtime == candidate.mtime,
               hit.size == candidate.size {
                summary = hit.summary
                nextCache[key] = SummaryCacheEntry(
                    mtime: hit.mtime, size: hit.size,
                    summary: hit.summary, lastAccess: now)
            } else {
                summary = PiAgentJsonlParser.summarize(file: candidate.url, range: range)
                nextCache[key] = SummaryCacheEntry(
                    mtime: candidate.mtime, size: candidate.size,
                    summary: summary, lastAccess: now)
            }

            if let summary { sessions.append(summary) }
        }

        sessions = Array(sessions
            .sorted { ($0.lastTimestamp ?? .distantPast) > ($1.lastTimestamp ?? .distantPast) }
            .prefix(maxRecentSessions))

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

private struct RecentLogFile: Sendable {
    let url: URL
    let mtime: Date
    let size: Int
}

private func recentJsonlFiles(roots: [String], skipSubagentPaths: Bool, limit: Int) -> [RecentLogFile] {
    let fm = FileManager.default
    var files: [RecentLogFile] = []
    for root in roots where fm.fileExists(atPath: root) {
        guard let enumerator = fm.enumerator(
            at: URL(fileURLWithPath: root),
            includingPropertiesForKeys: [
                .contentModificationDateKey,
                .fileSizeKey,
                .isRegularFileKey
            ]
        ) else {
            continue
        }

        for case let file as URL in enumerator where file.pathExtension == "jsonl" {
            guard !skipSubagentPaths || !file.pathComponents.contains("subagent"),
                  let values = try? file.resourceValues(forKeys: [
                    .contentModificationDateKey,
                    .fileSizeKey,
                    .isRegularFileKey
                  ]),
                  values.isRegularFile != false,
                  let mtime = values.contentModificationDate else {
                continue
            }
            files.append(RecentLogFile(url: file, mtime: mtime, size: values.fileSize ?? 0))
        }
    }
    return Array(files
        .sorted { $0.mtime > $1.mtime }
        .prefix(max(0, limit)))
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
