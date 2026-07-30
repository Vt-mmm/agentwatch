// Tổng hợp stats CẢ NGÀY/TUẦN: quét mọi session JSONL, parse tokens / cost / count
// per source. Khác với SessionWatcher (1 session, live) — đây là batch aggregation.
//
// Reuse JsonlParser.parseSession để khỏi viết lại logic token đếm.

import Foundation

public enum TokenAccountingRule: String, Sendable, Codable, Equatable {
    /// Claude and Pi report uncached input, cache reads/writes, and output as
    /// additive buckets. Reasoning is a breakdown of output, not an extra bucket.
    case additiveCacheBuckets
    /// Codex/OpenAI report cached input inside input and reasoning inside output.
    case inclusiveBreakdowns

    public var label: String {
        switch self {
        case .additiveCacheBuckets:
            return "input + output + cache read + cache write"
        case .inclusiveBreakdowns:
            return "input + output (cache/reasoning are included)"
        }
    }
}

public enum UsageCostBasis: String, Sendable, Codable, Equatable {
    /// Cost persisted by the agent/provider in the source log.
    case reported
    /// Cost reconstructed from observed tokens and Agent Watch's price table.
    case estimated
    /// The source did not expose cost and no trustworthy estimate was available.
    case unavailable

    public var label: String {
        switch self {
        case .reported:    return "reported by source"
        case .estimated:   return "estimated"
        case .unavailable: return "unavailable"
        }
    }
}

public enum UsageScopePrecision: String, Sendable, Codable, Equatable {
    /// Every counted prompt/tool/usage event falls inside the selected report range.
    case exactRange
    /// The source only exposed a cumulative checkpoint without a pre-range baseline.
    case partialRange
    /// A live/full-session snapshot; must not be presented as period-exact.
    case wholeSession

    public var label: String {
        switch self {
        case .exactRange:   return "exact selected range"
        case .partialRange: return "partial selected range"
        case .wholeSession: return "whole session"
        }
    }
}

public struct SessionTitleChange: Identifiable, Sendable, Equatable {
    public let timestamp: Date?
    public let timestampString: String
    public let title: String

    public init(timestamp: Date?, timestampString: String, title: String) {
        self.timestamp = timestamp
        self.timestampString = timestampString
        self.title = title
    }

    public var id: String {
        "\(timestampString)|\(title)"
    }
}

/// Snapshot 1 session để hiển thị trong dashboard.
public struct SessionSummary: Identifiable, Sendable, Equatable {
    public let id: String                  // session uuid
    /// Human task/session title set by the operator inside the agent UI.
    /// For PiAgent this is the canonical task axis used by Agent Watch reports.
    public let sessionTitle: String?
    /// Ordered PiAgent session-title changes captured from `session_info`.
    /// Empty for sources that do not expose a rename timeline.
    public let titleHistory: [SessionTitleChange]
    public let projectDisplay: String
    public let source: SessionSource
    public let model: String
    public let modelFamily: ModelFamily
    public let inputTokens: Int
    public let outputTokens: Int
    public let reasoningTokens: Int
    public let cacheReadTokens: Int
    public let cacheWriteTokens: Int
    public let cost: Double
    public let firstTimestamp: Date?
    public let lastTimestamp: Date?
    public let promptCount: Int            // số user message
    public let toolCallCount: Int
    /// Path tới JSONL file — detail sheet re-parse từ đây để hiện events/tools.
    public let fileURL: URL?
    /// Số lần invoke tool "Agent" (spawn subagent) — heuristic phát hiện
    /// session bị subagent loop tốn token.
    public let agentCount: Int
    /// Agent thinking/reasoning mode when the source exposes it.
    public let thinkingLevel: String?
    /// Defines which usage buckets are additive for this source.
    public let tokenAccountingRule: TokenAccountingRule
    /// Distinguishes provider-reported cost from an Agent Watch estimate.
    public let costBasis: UsageCostBasis
    /// States whether the numbers are exact for the selected report period.
    public let usageScope: UsageScopePrecision
    /// Human-readable data-quality caveats carried into reports.
    public let dataWarnings: [String]

    public init(id: String, sessionTitle: String? = nil,
                titleHistory: [SessionTitleChange] = [],
                projectDisplay: String, source: SessionSource,
                model: String, modelFamily: ModelFamily,
                inputTokens: Int, outputTokens: Int, reasoningTokens: Int = 0,
                cacheReadTokens: Int, cacheWriteTokens: Int,
                cost: Double,
                firstTimestamp: Date?, lastTimestamp: Date?,
                promptCount: Int, toolCallCount: Int,
                fileURL: URL? = nil,
                agentCount: Int = 0,
                thinkingLevel: String? = nil,
                tokenAccountingRule: TokenAccountingRule? = nil,
                costBasis: UsageCostBasis = .estimated,
                usageScope: UsageScopePrecision = .wholeSession,
                dataWarnings: [String] = []) {
        self.id = id
        self.sessionTitle = Self.cleanTitle(sessionTitle)
        self.titleHistory = titleHistory.compactMap { change in
            guard let clean = Self.cleanTitle(change.title) else { return nil }
            return SessionTitleChange(
                timestamp: change.timestamp,
                timestampString: change.timestampString,
                title: clean
            )
        }
        self.projectDisplay = projectDisplay; self.source = source
        self.model = model; self.modelFamily = modelFamily
        self.inputTokens = inputTokens; self.outputTokens = outputTokens
        self.reasoningTokens = reasoningTokens
        self.cacheReadTokens = cacheReadTokens; self.cacheWriteTokens = cacheWriteTokens
        self.cost = cost
        self.firstTimestamp = firstTimestamp; self.lastTimestamp = lastTimestamp
        self.promptCount = promptCount; self.toolCallCount = toolCallCount
        self.fileURL = fileURL
        self.agentCount = agentCount
        self.thinkingLevel = Self.cleanTitle(thinkingLevel)
        self.tokenAccountingRule = tokenAccountingRule
            ?? (source == .codex ? .inclusiveBreakdowns : .additiveCacheBuckets)
        self.costBasis = costBasis
        self.usageScope = usageScope
        self.dataWarnings = dataWarnings
    }

    public var totalTokens: Int {
        switch tokenAccountingRule {
        case .additiveCacheBuckets:
            return inputTokens + outputTokens + cacheReadTokens + cacheWriteTokens
        case .inclusiveBreakdowns:
            return inputTokens + outputTokens
        }
    }

    public var displayTitle: String {
        sessionTitle ?? projectDisplay
    }

    /// Stable cross-agent identity for audit, risk and report joins.
    public var auditKey: String {
        "\(source.rawValue)|\(id)"
    }

    public var hasTaskSessionTitle: Bool {
        guard let sessionTitle else { return false }
        return !Self.isGenericTaskTitle(sessionTitle)
    }

    public var titleChangeCount: Int {
        titleHistory.count
    }

    public var firstTitleSetAt: Date? {
        titleHistory.compactMap(\.timestamp).first
    }

    public var lastTitleSetAt: Date? {
        titleHistory.compactMap(\.timestamp).last
    }

    /// Cache hit rate follows the source schema:
    /// - Claude/Pi: cacheRead is a separate input bucket.
    /// - Codex: cached input is already included in input.
    public var cacheHitRate: Double {
        let denom: Int
        switch tokenAccountingRule {
        case .additiveCacheBuckets:
            denom = inputTokens + cacheReadTokens
        case .inclusiveBreakdowns:
            denom = inputTokens
        }
        return denom > 0 ? Double(cacheReadTokens) / Double(denom) : 0
    }

    public var cacheHitRateFormula: String {
        switch tokenAccountingRule {
        case .additiveCacheBuckets:
            return "cache read / (input + cache read)"
        case .inclusiveBreakdowns:
            return "cached input / input"
        }
    }

    /// Cost trung bình mỗi user prompt — dùng để detect outlier khi 1 prompt
    /// "đốt" quá nhiều cost so với session khác.
    public var costPerPrompt: Double {
        promptCount > 0 ? cost / Double(promptCount) : cost
    }

    private static func cleanTitle(_ raw: String?) -> String? {
        guard let raw else { return nil }
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    private static func isGenericTaskTitle(_ raw: String) -> Bool {
        let compact = raw
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .folding(options: [.diacriticInsensitive, .caseInsensitive], locale: .current)
            .lowercased()
        if compact.count < 4 { return true }
        let generic: Set<String> = [
            "session", "new session", "untitled", "working", "work",
            "task", "default", "pi", "piagent", "pi agent"
        ]
        return generic.contains(compact)
    }
}

/// Aggregate metrics cho dashboard.
public struct InventoryAggregate: Sendable, Equatable {
    public let sessionCount: Int
    public let totalCost: Double
    public let reportedCost: Double
    public let estimatedCost: Double
    public let unavailableCostSessionCount: Int
    public let totalTokens: Int
    public let inputTokens: Int
    public let outputTokens: Int
    public let reasoningTokens: Int
    public let cacheReadTokens: Int
    public let cacheWriteTokens: Int
    public let totalToolCalls: Int

    public static let zero = InventoryAggregate(
        sessionCount: 0, totalCost: 0, reportedCost: 0, estimatedCost: 0,
        unavailableCostSessionCount: 0, totalTokens: 0,
        inputTokens: 0, outputTokens: 0, reasoningTokens: 0, cacheReadTokens: 0,
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
        // v0.7.0: Codex sessions từ ~/.codex/sessions/.
        out.append(contentsOf: CodexInventory.list(in: range))
        // v0.9.0: PiAgent sessions từ ~/.pi/agent/sessions/, gồm subagent runs.
        out.append(contentsOf: PiAgentInventory.list(in: range))

        // Sort cost first, then totalTokens so subscription/zero-cost agent logs
        // still surface when they burn many tokens.
        return out.sorted { a, b in
            if a.cost != b.cost { return a.cost > b.cost }
            return a.totalTokens > b.totalTokens
        }
    }

    /// Quick aggregate cho summary cards.
    public static func aggregate(_ sessions: [SessionSummary]) -> InventoryAggregate {
        var agg = InventoryAggregate.zero
        var input = 0, output = 0, reasoning = 0, cr = 0, cw = 0, tools = 0, cost = 0.0
        var reportedCost = 0.0
        var estimatedCost = 0.0
        var unavailableCostSessionCount = 0
        var totalTokens = 0
        for s in sessions {
            input  += s.inputTokens
            output += s.outputTokens
            reasoning += s.reasoningTokens
            cr     += s.cacheReadTokens
            cw     += s.cacheWriteTokens
            tools  += s.toolCallCount
            cost   += s.cost
            totalTokens += s.totalTokens
            switch s.costBasis {
            case .reported:
                reportedCost += s.cost
            case .estimated:
                estimatedCost += s.cost
            case .unavailable:
                unavailableCostSessionCount += 1
            }
        }
        agg = InventoryAggregate(
            sessionCount: sessions.count,
            totalCost: cost,
            reportedCost: reportedCost,
            estimatedCost: estimatedCost,
            unavailableCostSessionCount: unavailableCostSessionCount,
            totalTokens: totalTokens,
            inputTokens: input, outputTokens: output, reasoningTokens: reasoning,
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
        let stats = JsonlParser.parseSession(at: file, range: range)
        guard let firstTs = parseISO(stats.startedAt),
              let lastTs = parseISO(stats.lastEventAt) else {
            return nil
        }

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
            firstTimestamp: firstTs,
            lastTimestamp: lastTs,
            promptCount: stats.promptCount,
            toolCallCount: stats.toolCalls,
            fileURL: file,
            agentCount: stats.agents.count,
            costBasis: stats.costBasis,
            usageScope: .exactRange,
            dataWarnings: stats.costBasis == .unavailable
                ? ["No versioned price quote for model '\(stats.model)'; cost is unavailable."]
                : []
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
