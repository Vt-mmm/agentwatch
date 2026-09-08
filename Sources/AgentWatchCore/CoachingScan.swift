// 1-pass scan trả về cả prompts + sessions cùng lúc, parallel parse với
// TaskGroup. Thay thế việc gọi PromptHistory.loadPrompts + SessionInventory.list
// + computeDailyCostTrend riêng (mỗi cái re-enumerate filesystem độc lập).
//
// Manual refresh discovers files once, reuses persistent per-scope results and
// resumes append-only logs. Reading a saved scope needs no filesystem scan.

import Foundation
import CryptoKit

struct CoachingFileResult: Sendable, Codable {
    let prompts: [PromptRecord]
    let summary: SessionSummary?
}

/// Kết quả 1 lần scan rộng. Caller slice cho từng dimension (current/prev/daily).
public struct CoachingScanResult: Sendable, Codable {
    public let prompts: [PromptRecord]
    public let sessions: [SessionSummary]
    public let candidateFileCount: Int
    public let sourceFiles: [SourceFileManifest]
    public let sourceRoots: [SourceRootManifest]
    public var catalogFingerprint: String? = nil
    public var aggregate: InventoryAggregate? = nil
    public var aggregateGroups: [CoachingAggregateKey: InventoryAggregate] = [:]
    public var cacheHitCount: Int = 0
    public var resumedFileCount: Int = 0
    public var sourceBytesRead: UInt64 = 0
}

private struct FileScanOutcome: Sendable {
    let result: CoachingFileResult
    var cacheHit = false
    var resumed = false
    var bytesRead: UInt64 = 0
    var stable = true
}

public enum CoachingScan {

    /// Scan toàn bộ session file có khả năng chạm `range`. Parallel parse mỗi file.
    /// Trả về cả prompt list lẫn session summary từ CÙNG 1 pass đọc file.
    /// `allowRecentGrowth` is retained for source compatibility; changed files
    /// are now always refreshed. Export uses `forceFullRead` or `captureManifest`.
    public static func scan(in range: Range<Date>,
                            allowRecentGrowth: Bool = false,
                            roots: AgentLogRoots = .current,
                            captureManifest: Bool = false,
                            forceFullRead: Bool = false,
                            store: CoachingQueryStore = .shared,
                            progress: (@Sendable (Int, Int) async -> Void)? = nil) async -> CoachingScanResult {
        let generation = await store.beginScan(in: range, roots: roots)
        let index = DesktopOriginIndex.shared()
        let candidates = collectCandidateFiles(in: range, roots: roots)
        await progress?(0, candidates.count)
        let revisions = candidates.map { candidate in
            FileRevision(path: candidate.url.path, source: candidate.source(via: index), stamp: LogFileStamp.read(candidate.url))
        }.sorted { $0.path < $1.path }
        let revisionEncoder = JSONEncoder()
        revisionEncoder.outputFormatting = [.sortedKeys]
        let fingerprint = revisions.allSatisfy { $0.stamp != nil }
            ? (try? revisionEncoder.encode(revisions)).map { SHA256.hash(data: $0).map { String(format: "%02x", $0) }.joined() }
            : nil
        if !captureManifest, !forceFullRead, let fingerprint,
           let saved = await store.snapshot(in: range, roots: roots),
           saved.result.catalogFingerprint == fingerprint, !Task.isCancelled {
            var result = saved.result
            result.cacheHitCount = candidates.count
            result.resumedFileCount = 0
            result.sourceBytesRead = 0
            await progress?(candidates.count, candidates.count)
            await store.saveSnapshot(result, range: range, roots: roots, generation: generation)
            await store.finishScan(in: range, roots: roots, generation: generation)
            return result
        }
        let before = captureManifest ? candidates.map { SourceFileManifest.inspect($0.url) } : []
        // Parallel parse — IO-bound trên SSD, CPU-bound bị JSON; TaskGroup
        // tận dụng cả 2.
        let results = await withTaskGroup(of: FileScanOutcome?.self) { group in
            let workerCount = min(4, candidates.count)
            var nextIndex = 0
            for _ in 0..<workerCount {
                let c = candidates[nextIndex]
                nextIndex += 1
                group.addTask {
                    await parseOne(file: c.url, slug: c.slug, display: c.display,
                                   source: c.source(via: index), range: range,
                                   bypassCache: captureManifest || forceFullRead, store: store)
                }
            }
            var collected: [FileScanOutcome] = []
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
                                       bypassCache: captureManifest || forceFullRead, store: store)
                    }
                }
            }
            return collected
        }
        var prompts: [PromptRecord] = []
        var sessions: [SessionSummary] = []
        for r in results {
            prompts.append(contentsOf: r.result.prompts)
            if let s = r.result.summary { sessions.append(s) }
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
        var result = CoachingScanResult(
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
        result.catalogFingerprint = fingerprint
        result.aggregate = SessionInventory.aggregate(result.sessions)
        result.aggregateGroups = CoachingAggregateKey.build(sessions: result.sessions, total: result.aggregate ?? .zero)
        result.cacheHitCount = results.filter(\.cacheHit).count
        result.resumedFileCount = results.filter(\.resumed).count
        result.sourceBytesRead = results.reduce(0) { $0 + $1.bytesRead }
        if !captureManifest, !forceFullRead, !Task.isCancelled, results.count == candidates.count,
           results.allSatisfy(\.stable) {
            await store.saveSnapshot(result, range: range, roots: roots, generation: generation)
        }
        await store.finishScan(in: range, roots: roots, generation: generation)
        return result
    }

    // MARK: - File enumeration

    private struct FileRevision: Codable {
        let path: String
        let source: SessionSource
        let stamp: LogFileStamp?
    }

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
                                 bypassCache: Bool, store: CoachingQueryStore) async -> FileScanOutcome? {
        guard !Task.isCancelled else { return nil }
        let key = CoachingQueryStore.fileKey(file, source: source, range: range)
        let stamp = LogFileStamp.read(file)
        let previous = bypassCache ? nil : await store.file(key)
        if let previous, previous.stamp == stamp {
            return FileScanOutcome(result: previous.result, cacheHit: true)
        }
        if !bypassCache, let stamp, await store.excludesRange(file: file, stamp: stamp, range: range) {
            return FileScanOutcome(result: CoachingFileResult(prompts: [], summary: nil), cacheHit: true)
        }
        let input = bypassCache ? nil : stamp.map { IncrementalLogInput(file: file, stamp: $0, previous: previous) }

        let result: CoachingFileResult
        if source == .codex {
            let parsed = input.map { CodexJsonlParser.scanIndexed(file: file, range: range, input: $0) }
                ?? CodexJsonlParser.scan(file: file, range: range)
            result = CoachingFileResult(prompts: parsed.prompts, summary: parsed.summary)
        } else if source == .piagent {
            let parsed = input.map { PiAgentJsonlParser.scanIndexed(file: file, range: range, input: $0) }
                ?? PiAgentJsonlParser.scan(file: file, range: range)
            result = CoachingFileResult(prompts: parsed.prompts, summary: parsed.summary)
        } else {
            let parsed = input.map { JsonlParser.scanIndexed(at: file, range: range, input: $0) }
                ?? JsonlParser.scanSession(at: file, range: range)
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
        let stable = input?.succeeded ?? (stamp != nil && LogFileStamp.read(file) == stamp)
        if !bypassCache, let stamp, stable {
            let cached = CachedLogFile(stamp: stamp, result: result, checkpoint: input?.checkpoint,
                                       firstTimestamp: input?.firstTimestamp, lastTimestamp: input?.lastTimestamp)
            await store.saveFile(cached, key: key)
            if input != nil { await store.saveBounds(file: file, value: cached) }
        }
        return FileScanOutcome(result: result, resumed: input?.resumed ?? false,
                               bytesRead: input?.bytesRead ?? stamp?.size ?? 0, stable: stable)
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
