// Publishes Claude session stats. The legacy watch APIs still poll for the CLI
// and tests, while the macOS app uses the one-shot snapshot APIs below.
// Two selection modes:
//   - pinned:        read one specific project folder
//   - followLatest:  select whichever session has the newest JSONL mtime
//
// Polling beats DispatchSourceFileSystemObject here because:
//   1. New session UUIDs create new files mid-watch — we'd need to re-bind
//      the source every time, which adds bug surface for no perceptible UX win.
//   2. JSONL append rate is low (≤a few lines/sec) — 1s polling is plenty.

import Foundation
import Observation

/// A point-in-time snapshot of token counts, used to build the rate sparkline.
public struct TokenSample: Sendable, Equatable {
    public let time: Date
    public let outputTokens: Int
    public let totalTokens: Int

    public init(time: Date, outputTokens: Int, totalTokens: Int) {
        self.time = time
        self.outputTokens = outputTokens
        self.totalTokens = totalTokens
    }
}

@Observable
@MainActor
public final class SessionWatcher {
    public private(set) var stats: SessionStats?
    public private(set) var isWatching: Bool = false
    public private(set) var lastRefreshAt: Date?

    /// Ring buffer of token snapshots, capped at 60 entries, used by the sparkline.
    public private(set) var tokenHistory: [TokenSample] = []

    /// True when watcher selects the most recently modified session across
    /// every project. False when pinned to a single folder.
    public private(set) var followLatest: Bool = false

    /// The folder the user explicitly pinned, if any.
    public private(set) var pinnedFolder: URL?

    /// The folder we are actually reading — equals pinnedFolder when pinned,
    /// equals the latest project's decoded folder when following.
    public private(set) var resolvedFolder: URL?

    private var pollTask: Task<Void, Never>?
    private var lastMtime: Date = .distantPast
    private var lastSessionURL: URL?

    public init() {}

    /// Pin to a specific project folder. Replaces any prior watch.
    public func startPinned(folder: URL, intervalSeconds: TimeInterval = 1.0) {
        startCommon(followLatest: false, pinned: folder, intervalSeconds: intervalSeconds)
    }

    /// Follow whichever project has the most recently modified JSONL.
    public func startFollowingLatest(intervalSeconds: TimeInterval = 1.0) {
        startCommon(followLatest: true, pinned: nil, intervalSeconds: intervalSeconds)
    }

    /// Audit-mode snapshot: chọn folder rồi đọc 1 lần, không tạo polling task.
    @discardableResult
    public func loadPinned(folder: URL) -> SessionStats? {
        configureSnapshot(followLatest: false, pinned: folder)
        return refreshNow()
    }

    /// Audit-mode snapshot: đọc session Claude mới nhất 1 lần, không poll nền.
    @discardableResult
    public func loadLatest() -> SessionStats? {
        configureSnapshot(followLatest: true, pinned: nil)
        return refreshNow()
    }

    /// Re-read current selection once. Dùng cho nút refresh trong app.
    @discardableResult
    public func refreshSelection() -> SessionStats? {
        refreshNow()
    }

    public func stop() {
        pollTask?.cancel()
        pollTask = nil
        isWatching = false
    }

    /// Run one parse pass synchronously. Exposed for tests and for SwiftUI
    /// onAppear flows that want an immediate fill before the timer fires.
    @discardableResult
    public func refreshNow() -> SessionStats? {
        let target = currentTargetSession()
        guard let sessionURL = target else {
            stats = nil
            resolvedFolder = nil
            lastRefreshAt = Date()
            return nil
        }
        let folder = URL(fileURLWithPath:
            ProjectPath.displayPath(for: sessionURL.deletingLastPathComponent().lastPathComponent))
        resolvedFolder = folder

        let mtime = ProjectPath.mtime(of: sessionURL)
        if sessionURL != lastSessionURL || mtime > lastMtime {
            stats = JsonlParser.parseSession(at: sessionURL)
            lastSessionURL = sessionURL
            lastMtime = mtime

            // Record token snapshot for sparkline — only when data actually changed.
            if let parsed = stats {
                let sample = TokenSample(
                    time: Date(),
                    outputTokens: parsed.outputTokens,
                    totalTokens: parsed.totalTokens
                )
                if tokenHistory.isEmpty || tokenHistory.last?.outputTokens != sample.outputTokens {
                    tokenHistory.append(sample)
                    if tokenHistory.count > 60 {
                        tokenHistory.removeFirst()
                    }
                }
            }
        }
        lastRefreshAt = Date()
        return stats
    }

    // MARK: - Private

    private func startCommon(followLatest: Bool, pinned: URL?,
                             intervalSeconds: TimeInterval) {
        stop()
        self.followLatest = followLatest
        self.pinnedFolder = pinned
        self.lastMtime = .distantPast
        self.lastSessionURL = nil
        self.tokenHistory = []
        self.isWatching = true

        let interval = max(0.2, intervalSeconds)
        pollTask = Task { @MainActor [weak self] in
            while !Task.isCancelled {
                self?.refreshNow()
                try? await Task.sleep(nanoseconds: UInt64(interval * 1_000_000_000))
            }
        }
    }

    private func configureSnapshot(followLatest: Bool, pinned: URL?) {
        stop()
        self.followLatest = followLatest
        self.pinnedFolder = pinned
        self.lastMtime = .distantPast
        self.lastSessionURL = nil
        self.tokenHistory = []
    }

    private func currentTargetSession() -> URL? {
        if followLatest {
            return ProjectPath.mostRecentSessionAcrossAllProjects()
        }
        guard let pinned = pinnedFolder else { return nil }
        return ProjectPath.latestSession(for: pinned)
    }
}
