import Foundation

public struct TaskSessionBinding: Codable, Sendable, Identifiable, Equatable {
    public var id: String = UUID().uuidString
    public let projectPath: String
    public let taskID: String
    public let taskRunID: String
    public let source: SessionSource
    public let sessionID: String
    public let start: Date
    public let end: Date?
    public let recordedAt: Date
    public init(projectPath: String, taskID: String, taskRunID: String, source: SessionSource,
                sessionID: String, start: Date, end: Date? = nil, recordedAt: Date = Date()) {
        self.projectPath = projectPath; self.taskID = taskID; self.taskRunID = taskRunID
        self.source = source; self.sessionID = sessionID; self.start = start; self.end = end; self.recordedAt = recordedAt
    }
    public func contains(_ time: Date) -> Bool { start <= time && (end.map { time < $0 } ?? true) }
}

public struct TaskBindingStore: Sendable {
    private let files: ReportFileStore
    public init(root: URL) { files = ReportFileStore(root: root) }
    public static var local: Self { Self(root: URL(fileURLWithPath: NSHomeDirectory())
        .appendingPathComponent("Library/Application Support/AgentWatch/task-bindings")) }
    public func load() throws -> [TaskSessionBinding] { try files.transaction { try read() } }
    @discardableResult public func save(_ binding: TaskSessionBinding) throws -> [TaskSessionBinding] {
        guard binding.projectPath.hasPrefix("/"), [binding.taskID, binding.taskRunID, binding.sessionID].allSatisfy({
            !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && $0.utf8.count <= 512 && !$0.contains("\u{0}")
        }), binding.start.timeIntervalSince1970.isFinite,
              binding.end.map({ $0 > binding.start && $0.timeIntervalSince1970.isFinite }) ?? true else {
            throw ReportValidationError.invalid("Liên kết task cần dự án, task/run/session và khoảng thời gian hợp lệ.")
        }
        return try files.transaction {
            var document = try readDocument()
            var bindings = document.current
            let others = bindings.filter { $0.id != binding.id }
            guard !others.contains(where: { old in
                old.source == binding.source && old.sessionID == binding.sessionID
                    && old.start < (binding.end ?? .distantFuture) && binding.start < (old.end ?? .distantFuture)
            }) else { throw ReportValidationError.invalid("Session đã có liên kết trong khoảng thời gian này. Không gộp hai task nhập nhằng.") }
            if let previous = bindings.first(where: { $0.id == binding.id }), previous != binding {
                document.prior.append(previous)
            }
            bindings.removeAll { $0.id == binding.id }; bindings.append(binding)
            document.current = bindings
            try files.write(ReportEncoding.encode(document), to: files.root.appendingPathComponent("bindings.json"))
            return bindings
        }
    }
    public func previousVersions(id: String) throws -> [TaskSessionBinding] {
        try files.transaction { try readDocument().prior.filter { $0.id == id } }
    }
    private struct Document: Codable {
        var version = 1
        var current: [TaskSessionBinding] = []
        var prior: [TaskSessionBinding] = []
    }
    private func read() throws -> [TaskSessionBinding] { try readDocument().current }
    private func readDocument() throws -> Document {
        let file = files.root.appendingPathComponent("bindings.json")
        guard FileManager.default.fileExists(atPath: file.path) else { return Document() }
        let data = try Data(contentsOf: file)
        if let legacy = try? ReportEncoding.decode([TaskSessionBinding].self, from: data) {
            return Document(current: legacy)
        }
        let document = try ReportEncoding.decode(Document.self, from: data)
        guard document.version == 1 else { throw ReportValidationError.invalid("Phiên bản kho liên kết chưa được hỗ trợ.") }
        return document
    }
}

public struct TaskTimelineEntry: Codable, Sendable, Identifiable {
    public let id: String
    public let recordedAt: Date
    public let sessionID: String
    public let taskRunID: String
    public let title: String
    public let basis: String
    public let localRef: String?
}

public struct TaskLifecycleItem: Codable, Sendable, Identifiable {
    public let id: String
    public let projectPath: String
    public let taskID: String
    public let runIDs: [String]
    public let sessionRefs: [String]
    public let modelIDs: [String]
    public let timeline: [TaskTimelineEntry]
    public let ledgerEntries: [UsageEntry]
    public let warnings: [String]
    public var totalTokens: Int { UsageLedger(entries: ledgerEntries).normalizedTokens.total }
    public var estimatedUSD: Decimal { UsageLedger(entries: ledgerEntries).knownCostSubtotal }
}

public struct TaskLifecycleSnapshot: Codable, Sendable {
    public let items: [TaskLifecycleItem]
    public let unallocatedTokens: Int
    public let unlinkedSessionCount: Int
    public let warnings: [String]
}

public enum TaskLifecycleBuilder {
    private struct Key: Hashable { let project: String; let task: String }
    private struct Bucket {
        var runs: Set<String> = [], sessions: Set<String> = [], models: Set<String> = []
        var timeline: [TaskTimelineEntry] = [], entries: [UsageEntry] = []
        var warnings: Set<String> = []
    }
    /// Usage is allocated per request time, never by whole-session title. A
    /// competing explicit binding leaves the request unallocated.
    public static func build(scan: CoachingScanResult, journals: [PiTaskJournalResult],
                             bindings: [TaskSessionBinding], range: Range<Date>, projectPath: String? = nil) -> TaskLifecycleSnapshot {
        let bindings = bindings.filter { projectPath == nil || $0.projectPath == projectPath }
        let links = journals.flatMap(\.links).filter { projectPath == nil || $0.projectPath == projectPath }
        let sessions = SessionAccounting.canonical(scan.sessions).filter { session in
            projectPath == nil || session.projectDisplay == projectPath
                || bindings.contains { $0.source == session.source && $0.sessionID == session.id }
                || links.contains { session.source == .piagent && $0.sessionID == session.id }
        }
        var buckets: [Key: Bucket] = [:]
        var allocated = UsageLedger(), all = UsageLedger()
        var linkedSessionKeys: Set<String> = []
        func ensure(_ key: Key, run: String, source: SessionSource, session: String) {
            var bucket = buckets[key] ?? Bucket()
            bucket.runs.insert(run); bucket.sessions.insert(source.rawValue + "|" + session)
            buckets[key] = bucket
        }
        for event in journals.flatMap(\.events) where range.contains(event.recordedAt) && (projectPath == nil || event.projectPath == projectPath) {
            let key = Key(project: event.projectPath, task: event.taskID)
            ensure(key, run: event.taskRunID, source: .piagent, session: event.sessionID)
            let title = [event.eventType, event.checkpointID, event.phase, event.status].compactMap { $0 }.joined(separator: " · ")
            buckets[key]?.timeline.append(TaskTimelineEntry(id: event.id, recordedAt: event.recordedAt,
                sessionID: event.sessionID, taskRunID: event.taskRunID, title: title,
                basis: "Nhật ký runtime; chưa xác nhận nghiệm thu", localRef: event.localRef))
            linkedSessionKeys.insert("piagent|" + event.sessionID)
        }
        for binding in bindings where binding.start < range.upperBound && (binding.end ?? .distantFuture) > range.lowerBound {
            let key = Key(project: binding.projectPath, task: binding.taskID)
            ensure(key, run: binding.taskRunID, source: binding.source, session: binding.sessionID)
            buckets[key]?.timeline.append(TaskTimelineEntry(id: binding.id, recordedAt: binding.start,
                sessionID: binding.sessionID, taskRunID: binding.taskRunID, title: "Liên kết session do người dùng xác nhận",
                basis: "Liên kết thủ công; không xác nhận task hoàn thành", localRef: nil))
        }
        // Canonical request identity wins across duplicated/imported sessions.
        var entrySession: [String: SessionSummary] = [:]
        var entryOwners: [String: Set<String>] = [:]
        for session in sessions {
            for entry in session.usageEntries ?? [] where range.contains(entry.timestamp) {
                all.upsert(entry)
                entryOwners[entry.id, default: []].insert(session.auditKey)
                entrySession[entry.id] = session
            }
        }
        var warnings = journals.flatMap(\.warnings) + all.warnings
        for entry in all.entries {
            guard entryOwners[entry.id]?.count == 1, let session = entrySession[entry.id] else { continue }
            var candidates: [(Key, String)] = bindings.filter {
                $0.source == session.source && $0.sessionID == session.id && $0.contains(entry.timestamp)
            }.map { (Key(project: $0.projectPath, task: $0.taskID), $0.taskRunID) }
            if session.source == .piagent {
                let eligible = links.filter { $0.sessionID == session.id && $0.projectPath == session.projectDisplay && $0.recordedAt <= entry.timestamp }
                if let latest = eligible.map(\.recordedAt).max() {
                    candidates += eligible.filter { $0.recordedAt == latest }.map { (Key(project: $0.projectPath, task: $0.taskID), $0.taskRunID) }
                }
            }
            let keys = Set(candidates.map { $0.0 })
            let runs = Set(candidates.map { $0.1 })
            guard keys.count == 1, runs.count == 1, let key = keys.first, let run = runs.first else { continue }
            ensure(key, run: run, source: session.source, session: session.id)
            buckets[key]?.entries.append(entry); buckets[key]?.models.insert(entry.modelID)
            linkedSessionKeys.insert(session.auditKey); allocated.upsert(entry)
        }
        let unallocated = max(0, all.normalizedTokens.total - allocated.normalizedTokens.total)
        if unallocated > 0 { warnings.append("\(unallocated) token chưa có liên kết task tường minh hoặc có liên kết nhập nhằng.") }
        if sessions.contains(where: { $0.usageEntries == nil }) { warnings.append("Một số session chỉ có tổng; không phân bổ tổng session vào từng task.") }
        let items = buckets.map { key, bucket in
            TaskLifecycleItem(id: key.project + "\u{0}" + key.task, projectPath: key.project, taskID: key.task,
                runIDs: bucket.runs.sorted(), sessionRefs: bucket.sessions.sorted(), modelIDs: bucket.models.sorted(),
                timeline: bucket.timeline.sorted { $0.recordedAt == $1.recordedAt ? $0.id < $1.id : $0.recordedAt < $1.recordedAt },
                ledgerEntries: bucket.entries, warnings: bucket.warnings.sorted())
        }.sorted { $0.taskID < $1.taskID }
        return TaskLifecycleSnapshot(items: items, unallocatedTokens: unallocated,
            unlinkedSessionCount: sessions.filter { !linkedSessionKeys.contains($0.auditKey) }.count, warnings: warnings)
    }
}
