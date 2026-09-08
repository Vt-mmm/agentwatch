import Foundation

public enum PromptProjectScope: String, Codable, CaseIterable, Sendable {
    case unknown, inScope, outOfScope
    public var label: String {
        switch self {
        case .unknown: "Chưa xác định"
        case .inScope: "Trong phạm vi"
        case .outOfScope: "Ngoài phạm vi"
        }
    }
}

public enum PromptTaskBasis: String, Codable, Sendable { case unassigned, taskJournal, humanConfirmed, sessionContext }
public enum ReportPromptOrigin: String, Codable, Sendable { case employee, agentContinuation, context }

/// Detailed exports may include sanitized user text. A journal binding proves
/// association, not business scope. Optional fields preserve older snapshots.
public struct ReportPromptActivity: Codable, Sendable, Equatable, Identifiable {
    public let id: String
    public let timestamp: Date
    public let app: String
    public let sessionRef: String
    public var observedProject: String
    public var summary: String = ""
    public var content: String?
    public var origin: ReportPromptOrigin?
    public var fileActivities: [ReportFileActivity]?
    public var sessionTitle: String?
    public var toolObservations: [String]?
    public var toolObservationCount: Int?
    public var workItemID: String?
    public var taskBasis: PromptTaskBasis = .unassigned
    public var scope: PromptProjectScope = .unknown
    public var scopeReason: String = ""
}

public struct ReportAppActivity: Codable, Sendable, Equatable, Identifiable {
    public let id: String
    public let name: String
    public let firstObservedAt: Date
    public let lastObservedAt: Date
    public let sessionCount: Int
    public let promptCount: Int
    public let usageRecordCount: Int
    public let tokens: Int
}

public struct ReportDailyActivity: Codable, Sendable, Equatable {
    public var prompts: [ReportPromptActivity]
    public let apps: [ReportAppActivity]

    public static func promptID(_ prompt: PromptRecord) -> String {
        "prompt-" + ReportEncoding.digest(Data(prompt.auditKey.utf8))
    }

    public static func build(scan: CoachingScanResult, period: DailyReportPeriod,
                             links: [JournalTaskLink], items: [ReportWorkItem], usage: [ReportUsageRecord]) -> Self {
        var seen = Set<String>()
        let prompts = scan.prompts.filter { period.contains($0.timestamp) }
            .sorted { $0.timestamp == $1.timestamp ? $0.auditKey < $1.auditKey : $0.timestamp < $1.timestamp }
            .filter { seen.insert($0.auditKey).inserted }
        let rows = prompts.map { prompt in
            var row = ReportPromptActivity(id: promptID(prompt), timestamp: prompt.timestamp,
                app: prompt.source.label, sessionRef: prompt.sessionAuditKey,
                observedProject: ShareText.clean(URL(fileURLWithPath: prompt.projectDisplay).lastPathComponent))
            if prompt.source == .piagent {
                let eligible = links.filter { $0.sessionID == prompt.sessionUuid && $0.projectPath == prompt.projectDisplay && $0.recordedAt <= prompt.timestamp }
                if let latest = eligible.map(\.recordedAt).max() {
                    let candidates = Set(eligible.filter { $0.recordedAt == latest }.map {
                        "task-" + ReportEncoding.digest(Data("\($0.projectPath)|\($0.taskID)".utf8))
                    })
                    if candidates.count == 1, let key = candidates.first, items.contains(where: { $0.id == key }) {
                        row.workItemID = key; row.taskBasis = .taskJournal
                    }
                }
            }
            return row
        }
        struct Accumulator {
            var dates: [Date] = []
            var sessions = Set<String>()
            var prompts = 0
            var requests = 0
            var tokens = 0
        }
        var apps: [String: Accumulator] = [:]
        for prompt in rows {
            apps[prompt.app, default: Accumulator()].dates.append(prompt.timestamp)
            apps[prompt.app, default: Accumulator()].sessions.insert(prompt.sessionRef)
            apps[prompt.app, default: Accumulator()].prompts += 1
        }
        let sessions = SessionAccounting.canonical(scan.sessions)
        for session in sessions {
            if let date = session.lastTimestamp, period.contains(date) {
                apps[session.source.label, default: Accumulator()].dates.append(date)
                apps[session.source.label, default: Accumulator()].sessions.insert(session.auditKey)
            }
        }
        // Attribute only when the ledger ID belongs to one observed app source.
        // Ambiguous Claude CLI/Desktop usage stays in its own explicit bucket.
        var sourcesByUsage: [String: Set<String>] = [:]
        var sessionsByUsage: [String: Set<String>] = [:]
        for session in sessions {
            for entry in session.usageEntries ?? [] where period.contains(entry.timestamp) {
                sourcesByUsage[entry.id, default: []].insert(session.source.label)
                sessionsByUsage[entry.id, default: []].insert(session.auditKey)
            }
        }
        for entry in usage {
            let names = sourcesByUsage[entry.id] ?? []
            let fallback = ["claude": "Claude (chưa rõ CLI/Desktop)", "codex": "Codex", "pi": "PiAgent"]
            let name = names.count == 1 ? names.first! : fallback[entry.agent] ?? "Agent chưa xác định"
            apps[name, default: Accumulator()].dates.append(entry.timestamp)
            apps[name, default: Accumulator()].sessions.formUnion(sessionsByUsage[entry.id] ?? [])
            apps[name, default: Accumulator()].requests += 1
            apps[name, default: Accumulator()].tokens += entry.tokens.total
        }
        return Self(prompts: rows, apps: apps.keys.sorted().map { name in
            let value = apps[name]!
            return ReportAppActivity(id: name, name: name, firstObservedAt: value.dates.min()!, lastObservedAt: value.dates.max()!,
                sessionCount: value.sessions.count, promptCount: value.prompts, usageRecordCount: value.requests, tokens: value.tokens)
        })
    }
}
