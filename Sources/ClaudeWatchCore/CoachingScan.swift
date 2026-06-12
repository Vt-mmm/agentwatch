// 1-pass scan trả về cả prompts + sessions cùng lúc, parallel parse với
// TaskGroup. Thay thế việc gọi PromptHistory.loadPrompts + SessionInventory.list
// + computeDailyCostTrend riêng (mỗi cái re-enumerate filesystem độc lập).
//
// Coaching reload trước: 9× scan dir (cur/prev/7×day × 1 source mỗi cái) →
// nay: 1× scan dir, slice trong memory. Tốc độ thực tế +5-10×.

import Foundation

/// Kết quả 1 lần scan rộng. Caller slice cho từng dimension (current/prev/daily).
public struct CoachingScanResult: Sendable {
    public let prompts: [PromptRecord]
    public let sessions: [SessionSummary]
}

public enum CoachingScan {

    /// Scan toàn bộ session file có khả năng chạm `range`. Parallel parse mỗi file.
    /// Trả về cả prompt list lẫn session summary từ CÙNG 1 pass đọc file.
    public static func scan(in range: ClosedRange<Date>) async -> CoachingScanResult {
        let index = DesktopOriginIndex.shared()
        let candidates = collectCandidateFiles(in: range)
        // Parallel parse — IO-bound trên SSD, CPU-bound bị JSON; TaskGroup
        // tận dụng cả 2.
        let results = await withTaskGroup(of: ScanOne?.self) { group in
            for c in candidates {
                group.addTask {
                    parseOne(file: c.url, slug: c.slug, display: c.display,
                             source: c.source(via: index), range: range)
                }
            }
            var collected: [ScanOne] = []
            for await r in group {
                if let r { collected.append(r) }
            }
            return collected
        }
        var prompts: [PromptRecord] = []
        var sessions: [SessionSummary] = []
        for r in results {
            prompts.append(contentsOf: r.prompts)
            if let s = r.summary { sessions.append(s) }
        }
        prompts.sort { $0.timestamp < $1.timestamp }
        sessions.sort { $0.cost > $1.cost }
        return CoachingScanResult(prompts: prompts, sessions: sessions)
    }

    // MARK: - File enumeration

    private struct Candidate {
        let url: URL
        let slug: String
        let display: String
        let isDesktopFolder: Bool  // true = local-agent-mode audit, false = projects/
        func source(via index: DesktopOriginIndex) -> SessionSource {
            if isDesktopFolder { return .desktop }
            let uuid = url.deletingPathExtension().lastPathComponent
            return index.classify(uuid: uuid)
        }
    }

    /// Liệt kê file có mtime ≥ range.lowerBound, từ cả CLI projects/ lẫn
    /// Desktop local-agent-mode-sessions/.
    private static func collectCandidateFiles(in range: ClosedRange<Date>) -> [Candidate] {
        var out: [Candidate] = []
        let fm = FileManager.default

        // CLI: ~/.claude/projects/<slug>/<uuid>.jsonl
        let projectsDir = NSHomeDirectory() + "/.claude/projects"
        if let projectDirs = try? fm.contentsOfDirectory(atPath: projectsDir) {
            for slug in projectDirs {
                let projectURL = URL(fileURLWithPath: projectsDir).appendingPathComponent(slug)
                guard let files = try? fm.contentsOfDirectory(at: projectURL,
                                                              includingPropertiesForKeys: nil) else {
                    continue
                }
                let display = ProjectPath.displayPath(for: slug)
                for file in files where file.pathExtension == "jsonl" {
                    if ProjectPath.mtime(of: file) < range.lowerBound { continue }
                    out.append(Candidate(url: file, slug: slug, display: display,
                                         isDesktopFolder: false))
                }
            }
        }

        // Desktop: ~/Library/.../local-agent-mode-sessions/.../audit.jsonl
        let desktopRoot = NSHomeDirectory()
            + "/Library/Application Support/Claude/local-agent-mode-sessions"
        if fm.fileExists(atPath: desktopRoot),
           let enumerator = fm.enumerator(at: URL(fileURLWithPath: desktopRoot),
                                          includingPropertiesForKeys: nil) {
            for case let url as URL in enumerator where url.lastPathComponent == "audit.jsonl" {
                if ProjectPath.mtime(of: url) < range.lowerBound { continue }
                let parent = url.deletingLastPathComponent()
                let slug = parent.lastPathComponent
                let display = "Desktop · " + parent.deletingLastPathComponent().lastPathComponent
                out.append(Candidate(url: url, slug: slug, display: display,
                                     isDesktopFolder: true))
            }
        }
        return out
    }

    // MARK: - Per-file parse

    /// Output combined: prompts trong range + session summary (nếu session chạm range).
    private struct ScanOne {
        let prompts: [PromptRecord]
        let summary: SessionSummary?
    }

    /// Parse 1 file: lấy SessionStats (cho summary) + extract user prompts.
    /// JsonlParser.parseSession đã handle full schema CLI + Desktop audit.
    private static func parseOne(file: URL, slug: String, display: String,
                                 source: SessionSource,
                                 range: ClosedRange<Date>) -> ScanOne? {
        let stats = JsonlParser.parseSession(at: file)
        let mtime = ProjectPath.mtime(of: file)
        let firstTs = parseISO(stats.startedAt) ?? mtime
        let lastTs = parseISO(stats.lastEventAt) ?? mtime

        // Session summary nếu session chạm range.
        let summary: SessionSummary? = (lastTs >= range.lowerBound && firstTs <= range.upperBound)
            ? SessionSummary(
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
                promptCount: max(stats.events.filter { $0.kind == .userMessage }.count,
                                 stats.messageCount / 2),
                toolCallCount: stats.toolCalls,
                fileURL: file
            )
            : nil

        // Prompts trong range — bao giờ cũng parse file 2 lần nay → đọc thêm 1 lần
        // RIÊNG cho prompt extraction để giữ full text (JsonlParser cap 160ch).
        let prompts = extractPromptsInRange(file: file, slug: slug, display: display,
                                            source: source, range: range)

        if summary == nil && prompts.isEmpty { return nil }
        return ScanOne(prompts: prompts, summary: summary)
    }

    /// Extract user prompts từ file, lọc theo range. Tách riêng vì JsonlParser
    /// truncate 160 char cho UI feed — coaching cần full text.
    private static func extractPromptsInRange(file: URL, slug: String, display: String,
                                              source: SessionSource,
                                              range: ClosedRange<Date>) -> [PromptRecord] {
        guard let data = try? Data(contentsOf: file),
              let raw = String(data: data, encoding: .utf8) else { return [] }
        let sessionUuid = file.deletingPathExtension().lastPathComponent

        var records: [PromptRecord] = []
        var lineIndex = 0
        raw.enumerateLines { line, _ in
            lineIndex += 1
            guard !line.isEmpty,
                  let lineData = line.data(using: .utf8),
                  let obj = try? JSONSerialization.jsonObject(with: lineData) as? [String: Any]
            else { return }
            guard (obj["type"] as? String) == "user" else { return }

            let tsStr = (obj["timestamp"] as? String)
                ?? (obj["_audit_timestamp"] as? String)
            guard let s = tsStr, let ts = parseISO(s), range.contains(ts) else { return }

            let text = extractUserText(from: obj["message"])
                .trimmingCharacters(in: .whitespacesAndNewlines)
            guard !text.isEmpty else { return }

            records.append(PromptRecord(
                id: "\(sessionUuid)-\(lineIndex)",
                timestamp: ts, projectSlug: slug, projectDisplay: display,
                sessionUuid: sessionUuid, text: text,
                score: PromptScorer.score(text),
                source: source
            ))
        }
        return records
    }

    private static func extractUserText(from message: Any?) -> String {
        guard let dict = message as? [String: Any] else { return "" }
        if let raw = dict["content"] as? String { return raw }
        guard let blocks = dict["content"] as? [[String: Any]] else { return "" }
        var pieces: [String] = []
        for block in blocks {
            guard (block["type"] as? String) == "text",
                  let txt = block["text"] as? String, !txt.isEmpty else { continue }
            pieces.append(txt)
        }
        return pieces.joined(separator: "\n")
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
