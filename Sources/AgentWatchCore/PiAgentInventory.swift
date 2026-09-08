import Foundation

public enum PiAgentInventory {
    public static var defaultRoot: String { AgentLogRoots.current.piSessions }

    public static func list(in range: Range<Date>, root: String = defaultRoot) -> [SessionSummary] {
        let fm = FileManager.default
        guard fm.fileExists(atPath: root),
              let enumerator = fm.enumerator(
                at: URL(fileURLWithPath: root),
                includingPropertiesForKeys: [.contentModificationDateKey]
              ) else {
            return []
        }

        var out: [SessionSummary] = []
        for case let url as URL in enumerator where url.pathExtension == "jsonl" {
            if let summary = PiAgentJsonlParser.summarize(file: url, range: range) {
                out.append(summary)
            }
        }
        return out
    }
}

public enum PiAgentJsonlParser {
    public static func summarize(file: URL, range: Range<Date>) -> SessionSummary? {
        scan(file: file, range: range).summary
    }

    /// Decode summary and prompts in one streaming pass.
    public static func scan(file: URL,
                            range: Range<Date>) -> AgentLogScanResult {
        let parsed = parse(file: file, includeEvents: false, range: range)
        let summary = makeSummary(from: parsed, file: file)
        let prompts = isSubagentFile(file) ? [] : parsed.prompts
        return AgentLogScanResult(summary: summary, prompts: prompts)
    }

    static func scanIndexed(file: URL, range: Range<Date>, input: IncrementalLogInput) -> AgentLogScanResult {
        let parsed = parse(file: file, includeEvents: false, range: range, input: input)
        return AgentLogScanResult(summary: makeSummary(from: parsed, file: file), prompts: isSubagentFile(file) ? [] : parsed.prompts)
    }

    private static func makeSummary(from parsed: Parsed, file: URL) -> SessionSummary? {
        guard parsed.firstTimestamp != nil, parsed.lastTimestamp != nil else { return nil }

        let family = ModelFamily.from(modelId: parsed.model)
        let ledger = parsed.ledger
        let costBasis = ledger.costBasis
        let cost = NSDecimalNumber(decimal: ledger.knownCostSubtotal).doubleValue

        return SessionSummary(
            id: parsed.sessionId,
            sessionTitle: parsed.sessionTitle,
            titleHistory: parsed.titleHistory,
            projectDisplay: parsed.projectDisplay,
            source: .piagent,
            model: parsed.model,
            modelFamily: family,
            inputTokens: parsed.inputTokens,
            outputTokens: parsed.outputTokens,
            reasoningTokens: parsed.reasoningTokens,
            cacheReadTokens: parsed.cacheReadTokens,
            cacheWriteTokens: parsed.cacheWriteTokens,
            cost: cost,
            firstTimestamp: parsed.firstTimestamp,
            lastTimestamp: parsed.lastTimestamp,
            promptCount: parsed.promptCount,
            toolCallCount: parsed.toolCalls,
            fileURL: file,
            agentCount: parsed.agentCount,
            thinkingLevel: parsed.thinkingLevel,
            tokenAccountingRule: .additiveCacheBuckets,
            costBasis: costBasis,
            usageScope: ledger.hasPartialUsage ? .partialRange : .exactRange,
            dataWarnings: ledger.warnings,
            usageEntries: ledger.entries
        )
    }

    public static func parseSession(
        at file: URL,
        range: Range<Date>? = nil,
        eventLimit: Int? = SessionStats.eventWindowSize
    ) -> SessionStats {
        let parsed = parse(file: file, includeEvents: true, range: range)
        var stats = SessionStats(
            sessionId: parsed.sessionId,
            projectSlug: parsed.projectSlug,
            filePath: file
        )
        stats.hasUsageLedger = true
        stats.usageLedger = parsed.ledger
        stats.sessionName = parsed.sessionTitle
        stats.model = parsed.model
        stats.thinkingLevel = parsed.thinkingLevel
        stats.startedAt = parsed.firstTimestampString
        stats.lastEventAt = parsed.lastTimestampString
        stats.messageCount = parsed.messageCount
        stats.promptCount = parsed.promptCount
        stats.inputTokens = parsed.inputTokens
        stats.outputTokens = parsed.outputTokens
        stats.reasoningTokens = parsed.reasoningTokens
        stats.cacheReadTokens = parsed.cacheReadTokens
        stats.cacheWriteTokens = parsed.cacheWriteTokens
        stats.toolCalls = parsed.toolCalls
        stats.tokenAccountingRule = .additiveCacheBuckets
        stats.events = parsed.events
        if let eventLimit, stats.events.count > eventLimit {
            stats.events = Array(stats.events.suffix(max(0, eventLimit)))
        }
        return stats
    }

    public static func extractPrompts(from file: URL,
                                      range: Range<Date>) -> [PromptRecord] {
        scan(file: file, range: range).prompts
    }

    private struct Parsed {
        var sessionId: String
        var sessionTitle: String?
        var titleHistory: [SessionTitleChange]
        var projectSlug: String
        var projectDisplay: String
        var model: String
        var thinkingLevel: String?
        var firstTimestamp: Date?
        var lastTimestamp: Date?
        var firstTimestampString: String
        var lastTimestampString: String
        var messageCount: Int
        var inputTokens: Int
        var outputTokens: Int
        var reasoningTokens: Int
        var cacheReadTokens: Int
        var cacheWriteTokens: Int
        var ledger: UsageLedger
        var promptCount: Int
        var toolCalls: Int
        var agentCount: Int
        var events: [SessionEvent]
        var prompts: [PromptRecord]
    }

    private struct ScanCheckpoint: Codable {
        var sessionId: String
        var sessionTitle: String?
        var titleHistory: [SessionTitleChange]
        var cwd: String?
        var projectName: String?
        var model: String
        var thinkingLevel: String?
        var firstTimestamp: Date?
        var lastTimestamp: Date?
        var firstTimestampString: String
        var lastTimestampString: String
        var messageCount: Int
        var inputTokens: Int
        var outputTokens: Int
        var reasoningTokens: Int
        var cacheReadTokens: Int
        var cacheWriteTokens: Int
        var ledger: UsageLedger
        var provider: String
        var promptCount: Int
        var toolCalls: Int
        var agentCount: Int
        var events: [SessionEvent]
        var prompts: [PromptRecord]
        var pendingTools: [String: Int]
        var eventCounter: Int
        var lineIndex: Int
        var isFork: Bool
        var forkCreatedAt: Date?
    }

    private static func parse(file: URL,
                              includeEvents: Bool,
                              range: Range<Date>? = nil,
                              input: IncrementalLogInput? = nil) -> Parsed {
        let saved = input?.restore(ScanCheckpoint.self)
        let fallbackId = file.deletingPathExtension().lastPathComponent
        var sessionId: String = saved.map { $0.sessionId } ?? fallbackId
        var sessionTitle: String? = saved.map { $0.sessionTitle } ?? nil
        var titleHistory: [SessionTitleChange] = saved.map { $0.titleHistory } ?? []
        var cwd: String? = saved.map { $0.cwd } ?? nil
        var projectName: String? = saved.map { $0.projectName } ?? nil
        var model: String = saved.map { $0.model } ?? ""
        var thinkingLevel: String? = saved.map { $0.thinkingLevel } ?? nil
        var firstTimestamp: Date? = saved.map { $0.firstTimestamp } ?? nil
        var lastTimestamp: Date? = saved.map { $0.lastTimestamp } ?? nil
        var firstTimestampString: String = saved.map { $0.firstTimestampString } ?? ""
        var lastTimestampString: String = saved.map { $0.lastTimestampString } ?? ""
        var messageCount: Int = saved.map { $0.messageCount } ?? 0
        var inputTokens: Int = saved.map { $0.inputTokens } ?? 0
        var outputTokens: Int = saved.map { $0.outputTokens } ?? 0
        var reasoningTokens: Int = saved.map { $0.reasoningTokens } ?? 0
        var cacheReadTokens: Int = saved.map { $0.cacheReadTokens } ?? 0
        var cacheWriteTokens: Int = saved.map { $0.cacheWriteTokens } ?? 0
        var ledger: UsageLedger = saved.map { $0.ledger } ?? UsageLedger()
        var provider: String = saved.map { $0.provider } ?? "unknown"
        var promptCount: Int = saved.map { $0.promptCount } ?? 0
        var toolCalls: Int = saved.map { $0.toolCalls } ?? 0
        var agentCount: Int = saved.map { $0.agentCount } ?? (isSubagentFile(file) ? 1 : 0)
        var events: [SessionEvent] = saved.map { $0.events } ?? []
        var prompts: [PromptRecord] = saved.map { $0.prompts } ?? []
        var pendingTools: [String: Int] = saved.map { $0.pendingTools } ?? [:]
        var eventCounter: Int = saved.map { $0.eventCounter } ?? 0
        var lineIndex: Int = saved.map { $0.lineIndex } ?? 0
        var isFork: Bool = saved.map { $0.isFork } ?? false
        var forkCreatedAt: Date? = saved.map { $0.forkCreatedAt } ?? nil

        let consume: (Data) -> Void = { lineData in
            guard !lineData.isEmpty else { return }
            lineIndex += 1
            guard let obj = try? JSONSerialization.jsonObject(with: lineData) as? [String: Any] else {
                ledger.recordWarning("Malformed JSONL records excluded; source coverage is partial.")
                return
            }

            let tsString = obj["timestamp"] as? String ?? ""
            let timestamp = parseISO(tsString)
            input?.observe(timestamp)
            if obj["type"] as? String == "session", obj["parentSession"] as? String != nil {
                isFork = true; forkCreatedAt = timestamp
                ledger.recordWarning("Pi fork inherited history is excluded; boundary or missing timestamps are uncertain.")
            }
            let belongsToRange = range == nil
                || timestamp.map { range!.contains($0) } == true
            let visibleAtRangeEnd = range == nil
                || timestamp.map { $0 < range!.upperBound } == true
            if let ts = timestamp, belongsToRange {
                if firstTimestamp == nil || ts < firstTimestamp! {
                    firstTimestamp = ts
                    firstTimestampString = tsString
                }
                if lastTimestamp == nil || ts > lastTimestamp! {
                    lastTimestamp = ts
                    lastTimestampString = tsString
                }
            }
            guard visibleAtRangeEnd else { return }

            switch obj["type"] as? String {
            case "session":
                if let id = obj["id"] as? String, !id.isEmpty { sessionId = id }
                if let c = obj["cwd"] as? String, !c.isEmpty { cwd = c }

            case "model_change":
                if let p = obj["provider"] as? String { provider = p }
                if let m = obj["modelId"] as? String, !m.isEmpty { model = m }

            case "thinking_level_change":
                if let level = obj["thinkingLevel"] as? String, !level.isEmpty {
                    thinkingLevel = level
                }

            case "session_info":
                if let name = obj["name"] as? String, !name.isEmpty {
                    let normalized = normalizedSessionTitle(name)
                    sessionTitle = normalized
                    if let normalized,
                       titleHistory.last?.title != normalized {
                        titleHistory.append(SessionTitleChange(
                            timestamp: parseISO(tsString),
                            timestampString: tsString,
                            title: normalized
                        ))
                    }
                    if name.hasPrefix("pi:") {
                        projectName = String(name.dropFirst(3))
                    } else if name.hasPrefix("subagent-") {
                        agentCount = max(agentCount, 1)
                    }
                }

            case "message":
                guard let msg = obj["message"] as? [String: Any],
                      let role = msg["role"] as? String else { return }
                if let p = msg["provider"] as? String { provider = p }
                if let m = msg["model"] as? String, !m.isEmpty {
                    model = m
                }
                guard belongsToRange else { return }
                if isFork {
                    // Pi writes a new header then copies old entries verbatim.
                    // Local entry IDs are short and only session-unique; do not
                    // use them as global provider request IDs across forks.
                    guard let forkCreatedAt, let timestamp, timestamp > forkCreatedAt else { return }
                }

                switch role {
                case "user":
                    let text = extractText(from: msg["content"])
                    let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
                    guard !trimmed.isEmpty else { return }
                    promptCount += 1
                    messageCount += 1
                    if includeEvents {
                        eventCounter += 1
                        events.append(SessionEvent(
                            id: "pi-user-\(eventCounter)",
                            timestamp: tsString,
                            kind: .userMessage,
                            summary: short(trimmed, max: 160)
                        ))
                    }
                    if !isSubagentFile(file),
                       let ts = parseISO(tsString),
                       !CoachingScan.isLikelySystemInjection(trimmed) {
                        prompts.append(PromptRecord(
                            id: "pi-\(sessionId)-\(lineIndex)",
                            timestamp: ts,
                            projectSlug: cwd ?? projectName ?? file.deletingLastPathComponent().lastPathComponent,
                            projectDisplay: displayProject(cwd: cwd, projectName: projectName),
                            sessionTitle: sessionTitle,
                            sessionUuid: sessionId,
                            text: trimmed,
                            score: PromptScorer.score(trimmed),
                            source: .piagent
                        ))
                    }

                case "assistant":
                    messageCount += 1
                    do {
                        let usage = msg["usage"] as? [String: Any] ?? [:]
                        let sourceCost = usage["cost"] as? [String: Any]
                        ledger.upsert(UsageEntry(
                            id: UsageIdentity.key(agent: "pi", provider: provider,
                                                  id: msg["id"] as? String ?? (obj["id"] as? String).map { sessionId + "|entry|" + $0 },
                                                  raw: lineData, sessionID: sessionId),
                            sessionID: sessionId, agent: "pi", provider: provider,
                            modelID: msg["model"] as? String ?? model,
                            timestamp: timestamp ?? .distantPast,
                            tokens: UsageTokens(input: UsageIdentity.count(usage["input"], required: true),
                                                output: UsageIdentity.count(usage["output"], required: true),
                                                cacheRead: intValue(usage["cacheRead"]),
                                                cacheWrite: intValue(usage["cacheWrite"]),
                                                cacheWrite1h: intValue(usage["cacheWrite1h"]),
                                                reasoning: intValue(usage["reasoning"])),
                            serviceTier: msg["serviceTier"] as? String,
                            agentEstimatedUSD: UsageIdentity.decimal(sourceCost?["total"]),
                            warnings: timestamp == nil ? ["Usage timestamp missing."] : []))
                    }
                    applyAssistantContent(
                        msg["content"],
                        timestamp: tsString,
                        includeEvents: includeEvents,
                        toolCalls: &toolCalls,
                        agentCount: &agentCount,
                        events: &events,
                        pendingTools: &pendingTools,
                        eventCounter: &eventCounter
                    )

                case "toolResult":
                    guard includeEvents,
                          let id = msg["toolCallId"] as? String,
                          let idx = pendingTools[id] ?? events.lastIndex(where: { $0.kind == .toolUse && $0.toolUseId == id }) else { return }
                    guard ToolEvidenceDigest.update(&events[idx], output: msg["content"], error: msg["isError"], timestamp: tsString) else { return }
                    events[idx].resultPreview = extractResult(from: msg["content"])
                    pendingTools.removeValue(forKey: id)

                default:
                    break
                }

            default:
                break
            }
        }

        if let input {
            input.read(state: {
                IncrementalLogInput.encode(ScanCheckpoint(
                    sessionId: sessionId,
                    sessionTitle: sessionTitle,
                    titleHistory: titleHistory,
                    cwd: cwd,
                    projectName: projectName,
                    model: model,
                    thinkingLevel: thinkingLevel,
                    firstTimestamp: firstTimestamp,
                    lastTimestamp: lastTimestamp,
                    firstTimestampString: firstTimestampString,
                    lastTimestampString: lastTimestampString,
                    messageCount: messageCount,
                    inputTokens: inputTokens,
                    outputTokens: outputTokens,
                    reasoningTokens: reasoningTokens,
                    cacheReadTokens: cacheReadTokens,
                    cacheWriteTokens: cacheWriteTokens,
                    ledger: ledger,
                    provider: provider,
                    promptCount: promptCount,
                    toolCalls: toolCalls,
                    agentCount: agentCount,
                    events: events,
                    prompts: prompts,
                    pendingTools: pendingTools,
                    eventCounter: eventCounter,
                    lineIndex: lineIndex,
                    isFork: isFork,
                    forkCreatedAt: forkCreatedAt))
            }, line: consume)
        } else {
            JsonlLineReader.forEachLineData(at: file, consume)
        }

        let totals = ledger.normalizedTokens
        inputTokens = totals.input; outputTokens = totals.output
        cacheReadTokens = totals.cacheRead; cacheWriteTokens = totals.cacheWrite
        reasoningTokens = totals.reasoning
        return Parsed(
            sessionId: sessionId,
            sessionTitle: sessionTitle,
            titleHistory: titleHistory,
            projectSlug: cwd ?? projectName ?? file.deletingLastPathComponent().lastPathComponent,
            projectDisplay: displayProject(cwd: cwd, projectName: projectName),
            model: model,
            thinkingLevel: thinkingLevel,
            firstTimestamp: firstTimestamp,
            lastTimestamp: lastTimestamp,
            firstTimestampString: firstTimestampString,
            lastTimestampString: lastTimestampString,
            messageCount: messageCount,
            inputTokens: inputTokens,
            outputTokens: outputTokens,
            reasoningTokens: reasoningTokens,
            cacheReadTokens: cacheReadTokens,
            cacheWriteTokens: cacheWriteTokens,
            ledger: ledger,
            promptCount: promptCount,
            toolCalls: toolCalls,
            agentCount: agentCount,
            events: events,
            prompts: prompts.map { $0.withSessionTitle(sessionTitle) }
        )
    }

    private static func normalizedSessionTitle(_ raw: String) -> String? {
        var name = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if name.hasPrefix("pi:") {
            name = String(name.dropFirst(3))
                .trimmingCharacters(in: .whitespacesAndNewlines)
        }
        return name.isEmpty ? nil : name
    }

    private static func applyAssistantContent(_ raw: Any?,
                                              timestamp: String,
                                              includeEvents: Bool,
                                              toolCalls: inout Int,
                                              agentCount: inout Int,
                                              events: inout [SessionEvent],
                                              pendingTools: inout [String: Int],
                                              eventCounter: inout Int) {
        guard let blocks = raw as? [[String: Any]] else { return }
        for block in blocks {
            switch block["type"] as? String {
            case "text":
                let text = block["text"] as? String ?? ""
                guard includeEvents, !text.isEmpty else { continue }
                eventCounter += 1
                events.append(SessionEvent(
                    id: "pi-text-\(eventCounter)",
                    timestamp: timestamp,
                    kind: .assistantText,
                    summary: short(text, max: 160)
                ))

            case "thinking":
                guard includeEvents else { continue }
                let thinking = block["thinking"] as? String ?? ""
                eventCounter += 1
                events.append(SessionEvent(
                    id: "pi-think-\(eventCounter)",
                    timestamp: timestamp,
                    kind: .assistantThinking,
                    summary: thinking.isEmpty ? "Thinking..." : short(thinking, max: 160)
                ))

            case "toolCall":
                toolCalls += 1
                let id = block["id"] as? String ?? ""
                let name = block["name"] as? String ?? "Tool"
                if name == "subagent" { agentCount += 1 }
                guard includeEvents else { continue }
                eventCounter += 1
                let eventId = id.isEmpty ? "pi-tool-\(eventCounter)" : id
                events.append(SessionEvent(
                    id: eventId,
                    timestamp: timestamp,
                    kind: .toolUse,
                    toolName: name,
                    toolUseId: id,
                    summary: summarizeTool(name: name, arguments: block["arguments"]),
                    completed: false, inputDigest: ToolEvidenceDigest.arguments(block["arguments"])
                ))
                if !id.isEmpty { pendingTools[id] = events.count - 1 }

            default:
                break
            }
        }
    }

    private static func displayProject(cwd: String?, projectName: String?) -> String {
        if let cwd, !cwd.isEmpty { return cwd }
        if let projectName, !projectName.isEmpty { return "PiAgent: \(projectName)" }
        return "(unknown)"
    }

    private static func extractText(from raw: Any?) -> String {
        if let s = raw as? String { return s }
        guard let blocks = raw as? [[String: Any]] else { return "" }
        return blocks.compactMap { block -> String? in
            guard block["type"] as? String == "text",
                  let text = block["text"] as? String,
                  !text.isEmpty else { return nil }
            return text
        }.joined(separator: "\n")
    }

    private static func extractResult(from raw: Any?) -> String? {
        let text = extractText(from: raw)
        if !text.isEmpty { return short(text, max: 600) }
        if let s = raw as? String, !s.isEmpty { return short(s, max: 600) }
        return nil
    }

    private static func summarizeTool(name: String, arguments: Any?) -> String {
        if let dict = arguments as? [String: Any] {
            for key in ["command", "path", "file_path", "query", "prompt", "task", "url", "text", "message"] {
                if let value = dict[key] as? String, !value.isEmpty {
                    return short(value, max: 400)
                }
            }
            if let data = try? JSONSerialization.data(withJSONObject: dict, options: [.sortedKeys]),
               let text = String(data: data, encoding: .utf8) {
                return short(text, max: 400)
            }
        }
        if let text = arguments as? String, !text.isEmpty { return short(text, max: 400) }
        return name
    }

    private static func isSubagentFile(_ file: URL) -> Bool {
        file.pathComponents.contains("subagent")
    }

    private static func short(_ s: String, max n: Int) -> String {
        String(s.replacingOccurrences(of: "\n", with: " ").prefix(n))
    }

    private static func intValue(_ raw: Any?) -> Int {
        UsageIdentity.count(raw)
    }

    private static func doubleValue(_ raw: Any?) -> Double {
        if let n = raw as? Double { return n }
        if let n = raw as? Int { return Double(n) }
        if let n = raw as? NSNumber { return n.doubleValue }
        if let s = raw as? String, let n = Double(s) { return n }
        return 0
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
