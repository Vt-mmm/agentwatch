import Foundation

public struct ContextPartition: Codable, Hashable, Sendable, Identifiable {
    public let projectPath: String
    public let sessionID: String
    public let taskRunID: String
    public let model: String
    public let thinkingLevel: String
    public var id: String { [projectPath, sessionID, taskRunID, model, thinkingLevel].joined(separator: "\u{0}") }
}

public struct ObservedRatio: Codable, Sendable {
    public let numerator: Double
    public let denominator: Double
    public let observed: Int
    public let comparable: Int
    public let coverage: InsightCoverage
    public var value: Double? { denominator > 0 && comparable > 0 ? numerator / denominator : nil }
}

public struct ContextLoopFinding: Codable, Sendable, Identifiable {
    public let id: String
    public let partition: ContextPartition
    public let toolName: String
    public let failed: Bool
    public let count: Int
    public let firstAt: Date
    public let lastAt: Date
    public let evidence: [ContextObservation]
    public var title: String { failed ? "Lặp cùng input và lỗi \(count) lần" : "Cùng input và output \(count) lần; cần kiểm tra tiến triển" }
}

public struct ContextEfficiencyGroup: Codable, Sendable, Identifiable {
    public let partition: ContextPartition
    public let taskID: String?
    public let eventCount: Int
    public let duplicateReads: ObservedRatio
    public let duplicateOutput: ObservedRatio
    public let utilization: ObservedRatio
    public let schemaShare: ObservedRatio
    public let lowConfidence: ObservedRatio
    public let averageActiveTools: Double?
    /// No definitive score when even one weighted lane or source coverage is missing.
    public let wasteScore: Int?
    public let wasteScoreEstimate: Int?
    public let evidence: [ContextObservation]
    public var id: String { partition.id }
}

public struct ContextEfficiencyAnalysis: Codable, Sendable {
    public let groups: [ContextEfficiencyGroup]
    public let loops: [ContextLoopFinding]
    public let unassignedEvents: Int
    public let coverage: InsightCoverage
    public let warnings: [String]
}

public enum ContextEfficiencyAnalyzer {
    private struct TurnKey: Hashable { let session: String; let turn: String }
    private struct ReadKey: Hashable { let tool: String; let input: String }
    private struct LoopKey: Equatable { let tool: String; let input: String; let output: String; let error: Bool }
    private struct Accumulator {
        var events: [ContextObservation] = []
        var reads = 0, comparableReads = 0, duplicates = 0
        var seen: [ReadKey: String] = [:]
        var selected: Set<String> = []
        var credited: Set<String> = []
        var selectionCount = 0, usedCount = 0
        var chainKey: LoopKey?
        var chain: [ContextObservation] = []
    }

    public static func analyze(_ snapshot: ContextTelemetrySnapshot, range: Range<Date>) -> ContextEfficiencyAnalysis {
        // Late turn_task_bound records may bind earlier tool observations. An
        // ambiguous binding stays unknown; no last-writer guess across tasks.
        var bindings: [TurnKey: Set<String>] = [:]
        for event in snapshot.events where event.event == "turn_task_bound" && event.recordedAt < range.upperBound {
            if let turn = event.turnID, let run = event.taskRunID {
                bindings[TurnKey(session: event.sessionID, turn: turn), default: []].insert(run)
            }
        }
        func partition(_ event: ContextObservation) -> ContextPartition? {
            var run = event.taskRunID
            if run == nil, let turn = event.turnID,
               let candidates = bindings[TurnKey(session: event.sessionID, turn: turn)], candidates.count == 1 { run = candidates.first }
            guard let run, !run.isEmpty else { return nil }
            return ContextPartition(projectPath: event.projectPath, sessionID: event.sessionID, taskRunID: run,
                                    model: event.model ?? "unknown", thinkingLevel: event.thinkingLevel ?? "unknown")
        }
        // Revisions of one tool call are not additional invocations. Resolve
        // them before loop detection so an old error cannot survive a later
        // correction as a separate retry. Equal-time conflicts stay unknown.
        struct RevisionKey: Hashable {
            let project: String; let session: String; let run: String; let event: String; let call: String
        }
        var revisions: [RevisionKey: ContextObservation] = [:]
        var conflicts: Set<RevisionKey> = []
        var observations: [ContextObservation] = []
        for event in snapshot.events where event.recordedAt < range.upperBound {
            guard ["tool_call", "tool_result"].contains(event.event), let call = event.toolCallID,
                  let group = partition(event) else { observations.append(event); continue }
            let key = RevisionKey(project: group.projectPath, session: group.sessionID, run: group.taskRunID, event: event.event, call: call)
            if let prior = revisions[key] {
                if event.recordedAt > prior.recordedAt { revisions[key] = event; conflicts.remove(key) }
                else if event.recordedAt == prior.recordedAt && event.id != prior.id { conflicts.insert(key) }
            } else { revisions[key] = event }
        }
        let conflictingIDs = Set(revisions.filter { conflicts.contains($0.key) }.map { $0.value.id })
        observations += revisions.map(\.value)
        let sourceOrder = Dictionary(snapshot.events.enumerated().map { ($0.element.id, $0.offset) }, uniquingKeysWith: min)
        observations.sort { $0.recordedAt == $1.recordedAt
            ? (sourceOrder[$0.id] ?? Int.max) < (sourceOrder[$1.id] ?? Int.max) : $0.recordedAt < $1.recordedAt }
        let coverage: InsightCoverage = conflicts.isEmpty ? snapshot.coverage : .partial
        var accumulators: [ContextPartition: Accumulator] = [:]
        var loops: [ContextLoopFinding] = []
        var unassigned = 0
        func flush(_ key: ContextPartition, _ value: inout Accumulator) {
            if value.chain.count >= 3, let first = value.chain.first, let last = value.chain.last {
                loops.append(ContextLoopFinding(id: first.id + "|" + last.id, partition: key,
                    toolName: first.toolName ?? "tool", failed: first.isError == true,
                    count: value.chain.count, firstAt: first.recordedAt, lastAt: last.recordedAt,
                    evidence: value.chain))
            }
            value.chain = []; value.chainKey = nil
        }
        for event in observations where range.contains(event.recordedAt) {
            guard let key = partition(event) else { unassigned += 1; continue }
            if conflictingIDs.contains(event.id) {
                // Unknown intervening output is a barrier, not a missing row
                // that lets retries on either side form an invented chain.
                for other in Array(accumulators.keys) where other.projectPath == key.projectPath
                    && other.sessionID == key.sessionID && other.taskRunID == key.taskRunID {
                    if var value = accumulators[other] { flush(other, &value); value.seen = [:]; accumulators[other] = value }
                }
                continue
            }
            var value = accumulators[key] ?? Accumulator()
            value.events.append(event)
            let tool = event.toolName ?? ""
            if event.event == "context_pack_injected" {
                value.selected = Set(event.selectedPaths)
                value.credited = []
                value.selectionCount += value.selected.count
            }
            if event.event == "tool_result" {
                let mutation = !event.changedPaths.isEmpty || (["write", "edit", "apply_patch", "patch"].contains(tool) && event.isError == false)
                if mutation {
                    let paths = event.changedPaths.isEmpty ? event.targetPath.map { [$0] } ?? [] : event.changedPaths
                    if event.isError == false {
                        for path in paths where value.selected.contains(path) && !value.credited.contains(path) {
                            value.credited.insert(path); value.usedCount += 1
                        }
                    }
                    // Mutation invalidates comparable reads across model/effort
                    // partitions of this same session/run, never another task.
                    accumulators[key] = value
                    for other in Array(accumulators.keys) where other.projectPath == key.projectPath
                        && other.sessionID == key.sessionID && other.taskRunID == key.taskRunID {
                        guard var changed = accumulators[other] else { continue }
                        changed.seen = changed.seen.filter { _, readPath in
                            !paths.isEmpty && !readPath.isEmpty && !paths.contains { path in
                                readPath == path || readPath == "." || path == "."
                                    || path.hasPrefix(readPath + "/") || readPath.hasPrefix(path + "/")
                            }
                        }
                        flush(other, &changed)
                        accumulators[other] = changed
                    }
                    value = accumulators[key] ?? value
                }
                if !mutation, let input = event.inputHash, let output = event.outputHash,
                   let failed = event.isError, event.toolCallID != nil, !tool.isEmpty {
                    let candidate = LoopKey(tool: tool, input: input, output: output, error: failed)
                    let gap = value.chain.last.map { event.recordedAt.timeIntervalSince($0.recordedAt) } ?? 0
                    if value.chainKey != candidate || gap < 0 || gap > 600 { flush(key, &value); value.chainKey = candidate }
                    if !value.chain.contains(where: { $0.toolCallID == event.toolCallID }) { value.chain.append(event) }
                } else { flush(key, &value) }
            }
            if event.event == "tool_call", ["read", "grep", "find", "ls"].contains(tool) {
                value.reads += 1
                if let hash = event.inputHash {
                    value.comparableReads += 1
                    let read = ReadKey(tool: tool, input: hash)
                    if value.seen[read] != nil { value.duplicates += 1 }
                    else { value.seen[read] = event.targetPath ?? "" }
                }
            }
            accumulators[key] = value
        }
        var groups: [ContextEfficiencyGroup] = []
        for key in accumulators.keys.sorted(by: { $0.id < $1.id }) {
            guard var value = accumulators[key] else { continue }
            flush(key, &value)
            let events = value.events
            let results = events.filter { $0.event == "tool_result" }
            let comparableResults = results.filter { $0.outputChars != nil && $0.repeated != nil }
            let outputs = comparableResults.reduce(0.0) { $0 + Double($1.outputChars ?? 0) }
            let duplicateOutputs = comparableResults.filter { $0.repeated == true }.reduce(0.0) { $0 + Double($1.outputChars ?? 0) }
            let prompts = events.filter { $0.event == "agent_prompt" }
            let schemas = prompts.filter { $0.systemPromptTokens != nil && $0.toolSchemaTokens != nil }
            let active = prompts.compactMap(\.activeTools)
            let packs = events.filter { $0.event == "context_pack" }
            let confidence = packs.filter { ["none", "low", "medium", "high"].contains($0.confidence ?? "") }
            let schemasTotal = schemas.reduce(0.0) { $0 + Double($1.toolSchemaTokens ?? 0) }
            let prefixTotal = schemas.reduce(0.0) { $0 + Double($1.toolSchemaTokens ?? 0) + Double($1.systemPromptTokens ?? 0) }
            func ratio(_ numerator: Double, _ denominator: Double, _ observed: Int, _ comparable: Int) -> ObservedRatio {
                ObservedRatio(numerator: numerator, denominator: denominator, observed: observed, comparable: comparable,
                    coverage: comparable == 0 ? .unavailable : comparable == observed && coverage == .complete ? .complete : .partial)
            }
            let reads = ratio(Double(value.duplicates), Double(value.comparableReads), value.reads, value.comparableReads)
            let output = ratio(duplicateOutputs, outputs, results.count, comparableResults.count)
            let schema = ratio(schemasTotal, prefixTotal, prompts.count, schemas.count)
            let low = ratio(Double(confidence.filter { ["none", "low"].contains($0.confidence ?? "") }.count), Double(confidence.count), packs.count, confidence.count)
            let averageActive = active.isEmpty ? nil : active.reduce(0.0) { $0 + Double($1) } / Double(active.count)
            let estimate: Int? = events.isEmpty ? nil : Int((100 * ((reads.value ?? 0) * 0.3
                + (output.value ?? 0) * 0.25 + min(1, (schema.value ?? 0) * 3) * 0.2
                + (low.value ?? 0) * 0.15 + min(1, max(0, ((averageActive ?? 0) - 12) / 24)) * 0.1)).rounded())
            let complete = [reads, output, schema, low].allSatisfy { $0.coverage == .complete && $0.value != nil }
                && !active.isEmpty && active.count == prompts.count && coverage == .complete
            let taskIDs = Set(events.compactMap(\.taskID))
            groups.append(ContextEfficiencyGroup(partition: key, taskID: taskIDs.count == 1 ? taskIDs.first : nil,
                eventCount: events.count, duplicateReads: reads, duplicateOutput: output,
                utilization: ratio(Double(value.usedCount), Double(value.selectionCount), value.selectionCount, value.selectionCount), schemaShare: schema,
                lowConfidence: low, averageActiveTools: averageActive, wasteScore: complete ? estimate : nil,
                wasteScoreEstimate: estimate, evidence: events))
        }
        var warnings = snapshot.warnings
        if !conflicts.isEmpty { warnings.append("\(conflicts.count) lần gọi có bản ghi cùng thời điểm nhưng xung đột; bỏ khỏi thống kê vòng lặp.") }
        if unassigned > 0 { warnings.append("\(unassigned) sự kiện chưa có liên kết task/run rõ ràng; không gộp để tính lặp.") }
        if groups.contains(where: { $0.wasteScore == nil }) { warnings.append("Điểm lãng phí chưa đủ bằng chứng ở một số nhóm; không coi phần thiếu là 0.") }
        return ContextEfficiencyAnalysis(groups: groups, loops: loops.sorted { $0.lastAt > $1.lastAt },
            unassignedEvents: unassigned, coverage: coverage, warnings: warnings)
    }
}
