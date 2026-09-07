// 1-pass scan trả về cả prompts + sessions cùng lúc, parallel parse với
// TaskGroup. Thay thế việc gọi PromptHistory.loadPrompts + SessionInventory.list
// + computeDailyCostTrend riêng (mỗi cái re-enumerate filesystem độc lập).
//
// Coaching reload trước: 9× scan dir (cur/prev/7×day × 1 source mỗi cái) →
// nay: 1× scan dir, slice trong memory. Tốc độ thực tế +5-10×.

import Foundation

struct CoachingFileResult: Sendable {
    let prompts: [PromptRecord]
    let summary: SessionSummary?
}

// MARK: - Parse result cache (P0 optimisation)

/// Cache kết quả parse JSONL theo (path, mtime, size). Thread-safe via actor.
/// Tránh re-parse file không đổi khi user reload snapshot cùng scope.
/// Giới hạn 1000 entry — evict theo lastAccess cũ nhất để tránh tăng vô hạn.
actor JsonlParseCache {
    static let shared = JsonlParseCache()

    private struct CachedSession {
        let mtime: Date
        let size: Int64
        let rangeLowerBound: Date
        let rangeUpperBound: Date
        let source: SessionSource
        let result: CoachingFileResult
        let parsedAt: Date
        var lastAccess: Date
    }

    private var cache: [String: CachedSession] = [:]
    private let maxEntries = 1000

    /// Trả về cached SessionStats nếu (mtime, size) không đổi; nil nếu stale.
    func get(path: String, mtime: Date, size: Int64,
             range: Range<Date>,
             source: SessionSource,
             allowRecentGrowth: Bool) -> CoachingFileResult? {
        guard var entry = cache[path],
              entry.rangeLowerBound == range.lowerBound,
              entry.rangeUpperBound == range.upperBound,
              entry.source == source else { return nil }
        let unchanged = entry.mtime == mtime && entry.size == size
        // Snapshot reload and immediate export often happen back-to-back while
        // the active agent is still appending to its JSONL. Coalesce only that
        // short burst; a later manual refresh must observe the new bytes.
        let recentlyParsed = allowRecentGrowth && Date().timeIntervalSince(entry.parsedAt) < 5
        guard unchanged || recentlyParsed else { return nil }
        // Cập nhật lastAccess để LRU eviction hoạt động đúng.
        entry.lastAccess = Date()
        cache[path] = entry
        return entry.result
    }

    /// Lưu kết quả parse vào cache, evict oldest entry nếu vượt 1000.
    func set(path: String, mtime: Date, size: Int64,
             range: Range<Date>,
             source: SessionSource,
             result: CoachingFileResult) {
        if cache.count >= maxEntries, let oldestKey = oldestKey() {
            cache.removeValue(forKey: oldestKey)
        }
        cache[path] = CachedSession(
            mtime: mtime,
            size: size,
            rangeLowerBound: range.lowerBound,
            rangeUpperBound: range.upperBound,
            source: source,
            result: result,
            parsedAt: Date(),
            lastAccess: Date()
        )
    }

    private func oldestKey() -> String? {
        cache.min(by: { $0.value.lastAccess < $1.value.lastAccess })?.key
    }
}

/// Kết quả 1 lần scan rộng. Caller slice cho từng dimension (current/prev/daily).
public struct CoachingScanResult: Sendable {
    public let prompts: [PromptRecord]
    public let sessions: [SessionSummary]
    public let candidateFileCount: Int
    public let sourceFiles: [SourceFileManifest]
    public let sourceRoots: [SourceRootManifest]
}

public enum CoachingScan {

    /// Scan toàn bộ session file có khả năng chạm `range`. Parallel parse mỗi file.
    /// Trả về cả prompt list lẫn session summary từ CÙNG 1 pass đọc file.
    public static func scan(in range: Range<Date>,
                            allowRecentGrowth: Bool = false,
                            roots: AgentLogRoots = .current,
                            captureManifest: Bool = false,
                            progress: (@Sendable (Int, Int) async -> Void)? = nil) async -> CoachingScanResult {
        let index = DesktopOriginIndex.shared()
        let candidates = collectCandidateFiles(in: range, roots: roots)
        await progress?(0, candidates.count)
        let before = captureManifest ? candidates.map { SourceFileManifest.inspect($0.url) } : []
        // Parallel parse — IO-bound trên SSD, CPU-bound bị JSON; TaskGroup
        // tận dụng cả 2.
        let results = await withTaskGroup(of: CoachingFileResult?.self) { group in
            let workerCount = min(4, candidates.count)
            var nextIndex = 0
            for _ in 0..<workerCount {
                let c = candidates[nextIndex]
                nextIndex += 1
                group.addTask {
                    await parseOne(file: c.url, slug: c.slug, display: c.display,
                                   source: c.source(via: index), range: range,
                                   allowRecentGrowth: allowRecentGrowth, bypassCache: captureManifest)
                }
            }
            var collected: [CoachingFileResult] = []
            var completed = 0
            while let r = await group.next() {
                if Task.isCancelled { group.cancelAll(); break }
                completed += 1
                if completed % 10 == 0 || completed == candidates.count { await progress?(completed, candidates.count) }
                if let r { collected.append(r) }
                if nextIndex < candidates.count {
                    let c = candidates[nextIndex]
                    nextIndex += 1
                    group.addTask {
                        await parseOne(file: c.url, slug: c.slug, display: c.display,
                                       source: c.source(via: index), range: range,
                                       allowRecentGrowth: allowRecentGrowth, bypassCache: captureManifest)
                    }
                }
            }
            return collected
        }
        var prompts: [PromptRecord] = []
        var sessions: [SessionSummary] = []
        for r in results {
            prompts.append(contentsOf: r.prompts)
            if let s = r.summary { sessions.append(s) }
        }
        sessions = SessionAccounting.canonical(sessions)
        var seenPrompts: Set<String> = []
        prompts = prompts.sorted {
            $0.timestamp == $1.timestamp ? $0.id < $1.id : $0.timestamp < $1.timestamp
        }.filter { seenPrompts.insert("\($0.source.rawValue)|\($0.sessionUuid)|\($0.timestamp.timeIntervalSince1970)|\($0.text)").inserted }
        sessions.sort {
            if $0.cost != $1.cost { return $0.cost > $1.cost }
            return $0.totalTokens > $1.totalTokens
        }
        return CoachingScanResult(
            prompts: prompts,
            sessions: sessions,
            candidateFileCount: candidates.count,
            sourceFiles: captureManifest ? zip(candidates, before).map { candidate, prior in
                let after = SourceFileManifest.inspect(candidate.url)
                return SourceFileManifest(path: after.path, byteCount: after.byteCount, sha256: after.sha256,
                                          modifiedAt: after.modifiedAt, malformedRecordCount: after.malformedRecordCount,
                                          readable: after.readable && prior.readable,
                                          changedDuringRead: after.changedDuringRead || prior.changedDuringRead || after.sha256 != prior.sha256)
            } : [],
            sourceRoots: [roots.claudeProjects, roots.claudeDesktop, roots.codexSessions, roots.codexArchived, roots.piSessions].map(SourceRootManifest.init)
        )
    }

    // MARK: - File enumeration

    private struct Candidate {
        let url: URL
        let slug: String
        let display: String
        let fixedSource: SessionSource?
        func source(via index: DesktopOriginIndex) -> SessionSource {
            if let fixedSource { return fixedSource }
            let uuid = url.deletingPathExtension().lastPathComponent
            return index.classify(uuid: uuid)
        }
    }

    /// Enumerate all source files; copied/imported logs can preserve an old mtime.
    private static func collectCandidateFiles(in range: Range<Date>, roots: AgentLogRoots) -> [Candidate] {
        var out: [Candidate] = []
        let fm = FileManager.default

        // CLI: ~/.claude/projects/<slug>/<uuid>.jsonl
        let projectsDir = roots.claudeProjects
        if let projectDirs = try? fm.contentsOfDirectory(atPath: projectsDir) {
            for slug in projectDirs {
                let projectURL = URL(fileURLWithPath: projectsDir).appendingPathComponent(slug)
                guard let files = fm.enumerator(at: projectURL, includingPropertiesForKeys: nil,
                                               options: [.skipsHiddenFiles]) else {
                    continue
                }
                let display = ProjectPath.displayPath(for: slug)
                for case let file as URL in files where file.pathExtension == "jsonl" {
                    out.append(Candidate(url: file, slug: slug, display: display,
                                         fixedSource: nil))
                }
            }
        }

        // Desktop: ~/Library/.../local-agent-mode-sessions/.../audit.jsonl
        let desktopRoot = roots.claudeDesktop
        if fm.fileExists(atPath: desktopRoot),
           let enumerator = fm.enumerator(at: URL(fileURLWithPath: desktopRoot),
                                          includingPropertiesForKeys: nil) {
            for case let url as URL in enumerator where url.lastPathComponent == "audit.jsonl" {
                let parent = url.deletingLastPathComponent()
                let slug = parent.lastPathComponent
                let display = "Desktop · " + parent.deletingLastPathComponent().lastPathComponent
                out.append(Candidate(url: url, slug: slug, display: display,
                                     fixedSource: .desktop))
            }
        }

        collectRecursiveJsonl(
            root: roots.codexSessions,
            source: .codex,
            slug: "codex",
            display: "Codex",
            range: range,
            into: &out
        )
        collectRecursiveJsonl(
            root: roots.codexArchived,
            source: .codex,
            slug: "codex-archived",
            display: "Codex archived",
            range: range,
            into: &out
        )
        collectRecursiveJsonl(
            root: roots.piSessions,
            source: .piagent,
            slug: "piagent",
            display: "PiAgent",
            range: range,
            into: &out
        )
        return out
    }

    private static func collectRecursiveJsonl(root: String,
                                              source: SessionSource,
                                              slug: String,
                                              display: String,
                                              range: Range<Date>,
                                              into out: inout [Candidate]) {
        let fm = FileManager.default
        guard fm.fileExists(atPath: root),
              let enumerator = fm.enumerator(
                at: URL(fileURLWithPath: root),
                includingPropertiesForKeys: [.contentModificationDateKey]
              ) else {
            return
        }
        for case let url as URL in enumerator where url.pathExtension == "jsonl" {
            out.append(Candidate(url: url, slug: slug, display: display, fixedSource: source))
        }
    }

    // MARK: - Per-file parse

    /// Output combined: prompts trong range + session summary (nếu session chạm range).
    /// Parse 1 file: lấy SessionStats (cho summary) + extract user prompts.
    /// JsonlParser.parseSession đã handle full schema CLI + Desktop audit.
    /// Cache hit: file không đổi (mtime + size) → bỏ qua parse, dùng stats cũ.
    private static func parseOne(file: URL, slug: String, display: String,
                                 source: SessionSource,
                                 range: Range<Date>,
                                 allowRecentGrowth: Bool, bypassCache: Bool) async -> CoachingFileResult? {
        let path = file.path
        let mtime = ProjectPath.mtime(of: file)
        let size = (try? file.resourceValues(forKeys: [.fileSizeKey]).fileSize)
            .flatMap { Int64($0) } ?? 0
        if !bypassCache, let cached = await JsonlParseCache.shared.get(
            path: path,
            mtime: mtime,
            size: size,
            range: range,
            source: source,
            allowRecentGrowth: allowRecentGrowth
        ) {
            return cached.summary == nil && cached.prompts.isEmpty ? nil : cached
        }

        let result: CoachingFileResult
        if source == .codex {
            let parsed = CodexJsonlParser.scan(file: file, range: range)
            result = CoachingFileResult(prompts: parsed.prompts, summary: parsed.summary)
        } else if source == .piagent {
            let parsed = PiAgentJsonlParser.scan(file: file, range: range)
            result = CoachingFileResult(prompts: parsed.prompts, summary: parsed.summary)
        } else {
            let parsed = JsonlParser.scanSession(at: file, range: range)
            let stats = parsed.stats
            let firstTs = parseISO(stats.startedAt)
            let lastTs = parseISO(stats.lastEventAt)
            let summary: SessionSummary? = if let firstTs, let lastTs {
                SessionSummary(
                    id: stats.sessionId,
                    projectDisplay: display,
                    source: source,
                    model: stats.model,
                    modelFamily: stats.modelFamily,
                    inputTokens: stats.inputTokens,
                    outputTokens: stats.outputTokens,
                    cacheReadTokens: stats.cacheReadTokens,
                    cacheWriteTokens: stats.cacheWriteTokens,
                    cost: stats.cost,
                    firstTimestamp: firstTs,
                    lastTimestamp: lastTs,
                    promptCount: stats.promptCount,
                    toolCallCount: stats.toolCalls,
                    fileURL: file,
                    agentCount: stats.agents.count,
                    costBasis: stats.costBasis,
                    usageScope: stats.usageLedger.hasPartialUsage ? .partialRange : .exactRange,
                    dataWarnings: stats.usageLedger.warnings,
                    usageEntries: stats.usageLedger.entries
                )
            } else {
                nil
            }
            let sessionUuid = file.deletingPathExtension().lastPathComponent
            let childSession = file.pathComponents.contains("subagents")
            let prompts = (childSession ? [] : parsed.prompts).compactMap { prompt -> PromptRecord? in
                let cleaned = stripSystemTags(prompt.text)
                guard !cleaned.isEmpty, !isLikelySystemInjection(cleaned) else { return nil }
                return PromptRecord(
                    id: "\(sessionUuid)-\(prompt.lineIndex)",
                    timestamp: prompt.timestamp,
                    projectSlug: slug,
                    projectDisplay: display,
                    sessionUuid: sessionUuid,
                    text: cleaned,
                    score: PromptScorer.score(cleaned),
                    source: source
                )
            }
            result = CoachingFileResult(prompts: prompts, summary: summary)
        }

        guard !Task.isCancelled else { return nil }
        await JsonlParseCache.shared.set(
            path: path,
            mtime: mtime,
            size: size,
            range: range,
            source: source,
            result: result
        )
        return result.summary == nil && result.prompts.isEmpty ? nil : result
    }

    /// True nếu text trông giống auto-injected message của Claude Code thay vì
    /// user's real prompt. Heuristic:
    /// - Pure punctuation / quá ngắn (< 3 alphanumeric chars) — vd ".", ",", "."
    /// - Bắt đầu bằng tag XML system (Claude Code dùng để wrap command output)
    /// - Compaction header standard
    /// - Slash command resume markers
    nonisolated static func isLikelySystemInjection(_ rawText: String) -> Bool {
        let text = rawText.trimmingCharacters(in: .whitespacesAndNewlines)
        // Quá ngắn — đếm alphanumeric chars, < 3 = noise (vd ".", "..", ",.")
        let alphaCount = text.unicodeScalars.filter {
            CharacterSet.alphanumerics.contains($0)
        }.count
        if alphaCount < 3 { return true }

        // Claude Code wrapper tags — chèn tự động cho slash command / hook output.
        let systemPrefixes = [
            "<command-name>",
            "<command-message>",
            "<command-stdout>",
            "<command-args>",
            "<local-command-stdout>",
            "<local-command-stderr>",
            "<system-reminder>",
            "<bash-stdout>",
            "<bash-stderr>",
            "<user-prompt-submit-hook>",
        ]
        for prefix in systemPrefixes where text.hasPrefix(prefix) { return true }

        // Compaction continuation header — Claude Code generate khi context full.
        if text.hasPrefix("This session is being continued from a previous conversation") {
            return true
        }
        if text.hasPrefix("Caveat:") && text.contains("<local-command-stdout>") {
            return true
        }

        return false
    }

    /// Loại bỏ `<tag>...</tag>` của các wrapper system Claude Code chèn vào user
    /// message (hook output, command name, system reminder, stdout). Để text
    /// còn lại đại diện cho prompt user gõ thật sự.
    nonisolated static func stripSystemTags(_ text: String) -> String {
        let tags = [
            "command-name", "command-message", "command-stdout", "command-args",
            "local-command-stdout", "local-command-stderr",
            "system-reminder", "bash-stdout", "bash-stderr",
            "user-prompt-submit-hook",
        ]
        var s = text
        for tag in tags {
            let pattern = "<\(tag)>[\\s\\S]*?</\(tag)>"
            if let re = try? NSRegularExpression(pattern: pattern, options: []) {
                let range = NSRange(s.startIndex..., in: s)
                s = re.stringByReplacingMatches(in: s, options: [], range: range, withTemplate: "")
            }
        }
        return s.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func parseISO(_ s: String) -> Date? {
        guard !s.isEmpty else { return nil }
        if let d = isoFractional.date(from: s) { return d }
        return isoPlain.date(from: s)
    }

    nonisolated(unsafe) private static let isoFractional: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f
    }()

    nonisolated(unsafe) private static let isoPlain: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime]
        return f
    }()
}
