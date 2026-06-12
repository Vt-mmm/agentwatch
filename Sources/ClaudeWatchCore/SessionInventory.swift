// Tổng hợp stats CẢ NGÀY/TUẦN: quét mọi session JSONL, parse tokens / cost / count
// per source. Khác với SessionWatcher (1 session, live) — đây là batch aggregation.
//
// Reuse JsonlParser.parseSession để khỏi viết lại logic token đếm.

import Foundation

/// Snapshot 1 session để hiển thị trong dashboard.
public struct SessionSummary: Identifiable, Sendable, Equatable {
    public let id: String                  // session uuid
    public let projectDisplay: String
    public let source: SessionSource
    public let model: String
    public let modelFamily: ModelFamily
    public let inputTokens: Int
    public let outputTokens: Int
    public let cacheReadTokens: Int
    public let cacheWriteTokens: Int
    public let cost: Double
    public let firstTimestamp: Date?
    public let lastTimestamp: Date?
    public let promptCount: Int            // số user message
    public let toolCallCount: Int

    public var totalTokens: Int {
        inputTokens + outputTokens + cacheReadTokens + cacheWriteTokens
    }
}

/// Aggregate metrics cho dashboard.
public struct InventoryAggregate: Sendable, Equatable {
    public let sessionCount: Int
    public let totalCost: Double
    public let totalTokens: Int
    public let inputTokens: Int
    public let outputTokens: Int
    public let cacheReadTokens: Int
    public let cacheWriteTokens: Int
    public let totalToolCalls: Int

    public static let zero = InventoryAggregate(
        sessionCount: 0, totalCost: 0, totalTokens: 0,
        inputTokens: 0, outputTokens: 0, cacheReadTokens: 0,
        cacheWriteTokens: 0, totalToolCalls: 0)
}

public enum SessionInventory {

    /// Liệt kê tất cả session "chạm" vào khoảng [start, end] — tức session có
    /// ít nhất 1 event trong range. Slice qua mtime để filter rẻ ở bước 1.
    public static func list(in range: ClosedRange<Date>) -> [SessionSummary] {
        let index = DesktopOriginIndex.shared()
        var out: [SessionSummary] = []

        out.append(contentsOf: listProjects(in: range, index: index))
        out.append(contentsOf: listDesktopAgent(in: range))

        // Sort theo cost giảm dần (top cost sessions lên đầu).
        return out.sorted { $0.cost > $1.cost }
    }

    /// Quick aggregate cho summary cards.
    public static func aggregate(_ sessions: [SessionSummary]) -> InventoryAggregate {
        var agg = InventoryAggregate.zero
        var input = 0, output = 0, cr = 0, cw = 0, tools = 0, cost = 0.0
        for s in sessions {
            input  += s.inputTokens
            output += s.outputTokens
            cr     += s.cacheReadTokens
            cw     += s.cacheWriteTokens
            tools  += s.toolCallCount
            cost   += s.cost
        }
        agg = InventoryAggregate(
            sessionCount: sessions.count,
            totalCost: cost,
            totalTokens: input + output + cr + cw,
            inputTokens: input, outputTokens: output,
            cacheReadTokens: cr, cacheWriteTokens: cw,
            totalToolCalls: tools
        )
        return agg
    }

    // MARK: - Internals

    private static func listProjects(in range: ClosedRange<Date>,
                                     index: DesktopOriginIndex) -> [SessionSummary] {
        let projectsDir = NSHomeDirectory() + "/.claude/projects"
        let fm = FileManager.default
        guard let projectDirs = try? fm.contentsOfDirectory(atPath: projectsDir) else {
            return []
        }
        var out: [SessionSummary] = []
        for slug in projectDirs {
            let projectURL = URL(fileURLWithPath: projectsDir).appendingPathComponent(slug)
            guard let files = try? fm.contentsOfDirectory(at: projectURL,
                                                          includingPropertiesForKeys: [.contentModificationDateKey]) else {
                continue
            }
            let display = ProjectPath.displayPath(for: slug)
            for file in files where file.pathExtension == "jsonl" {
                // Rẻ: skip nếu mtime trước range.lowerBound (file không thể có event trong range).
                let mt = ProjectPath.mtime(of: file)
                if mt < range.lowerBound { continue }

                let uuid = file.deletingPathExtension().lastPathComponent
                let source = index.classify(uuid: uuid)
                if let summary = summarize(file: file, slug: slug, display: display,
                                           source: source, range: range) {
                    out.append(summary)
                }
            }
        }
        return out
    }

    private static func listDesktopAgent(in range: ClosedRange<Date>) -> [SessionSummary] {
        let root = NSHomeDirectory()
            + "/Library/Application Support/Claude/local-agent-mode-sessions"
        let fm = FileManager.default
        guard fm.fileExists(atPath: root),
              let enumerator = fm.enumerator(at: URL(fileURLWithPath: root),
                                              includingPropertiesForKeys: [.contentModificationDateKey]) else {
            return []
        }
        var out: [SessionSummary] = []
        for case let url as URL in enumerator where url.lastPathComponent == "audit.jsonl" {
            let mt = ProjectPath.mtime(of: url)
            if mt < range.lowerBound { continue }

            let parent = url.deletingLastPathComponent()
            let slug = parent.lastPathComponent
            let display = "Desktop · " + parent.deletingLastPathComponent().lastPathComponent
            if let summary = summarize(file: url, slug: slug, display: display,
                                       source: .desktop, range: range) {
                out.append(summary)
            }
        }
        return out
    }

    /// Parse 1 JSONL file, tính tokens/cost, lọc events theo range. Trả nil nếu
    /// session không có event nào trong range.
    private static func summarize(file: URL, slug: String, display: String,
                                  source: SessionSource,
                                  range: ClosedRange<Date>) -> SessionSummary? {
        let stats = JsonlParser.parseSession(at: file)
        // Check: session có chạm range không? Dùng lastEventAt + startedAt;
        // fallback file mtime nếu parse fail (e.g. Desktop audit format).
        let mtime = ProjectPath.mtime(of: file)
        let firstTs = parseISO(stats.startedAt) ?? mtime
        let lastTs = parseISO(stats.lastEventAt) ?? mtime
        guard lastTs >= range.lowerBound, firstTs <= range.upperBound else {
            return nil
        }

        // Đếm user prompt từ events (events đã bị cap 80 — fallback: 0 if not visible).
        let promptCount = stats.events.filter { $0.kind == .userMessage }.count

        return SessionSummary(
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
            firstTimestamp: firstTs as Date?,
            lastTimestamp: lastTs as Date?,
            promptCount: max(promptCount, stats.messageCount / 2),  // assistant + user
            toolCallCount: stats.toolCalls
        )
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
