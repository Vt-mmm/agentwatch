import Foundation
import SQLite3

public enum HistoryRecordKind: String, Codable, Sendable { case prompt, usage, task }

/// Search stays local. Image payloads and tool output are never indexed here.
public struct InsightHistoryRecord: Codable, Sendable, Identifiable {
    public let id: String
    public let timestamp: Date
    public let kind: HistoryRecordKind
    public let text: String
    public let sessionID: String
    public let localRef: String?
    public let usage: UsageEntry?

    public init(id: String, timestamp: Date, kind: HistoryRecordKind, text: String,
                sessionID: String, localRef: String? = nil, usage: UsageEntry? = nil) {
        self.id = id; self.timestamp = timestamp; self.kind = kind; self.text = text
        self.sessionID = sessionID; self.localRef = localRef; self.usage = usage
    }

    public static func collect(scan: CoachingScanResult, lifecycle: TaskLifecycleSnapshot,
                               projectPath: String) -> [Self] {
        let linked = Set(lifecycle.items.flatMap(\.sessionRefs))
        let sessions = SessionAccounting.canonical(scan.sessions).filter {
            $0.projectDisplay == projectPath || linked.contains($0.auditKey)
        }
        let keys = Set(sessions.map(\.auditKey))
        let files = Dictionary(sessions.compactMap { session in session.fileURL.map { (session.auditKey, $0.path) } }, uniquingKeysWith: { a, _ in a })
        var records = scan.prompts.filter { keys.contains($0.sessionAuditKey) }.map {
            Self(id: "prompt|" + $0.auditKey, timestamp: $0.timestamp, kind: .prompt,
                 text: $0.text, sessionID: $0.sessionUuid, localRef: files[$0.sessionAuditKey])
        }
        let ledger = UsageLedger(entries: sessions.flatMap { $0.usageEntries ?? [] })
        records += ledger.entries.map {
            Self(id: "usage|" + $0.id, timestamp: $0.timestamp, kind: .usage,
                 text: [$0.modelID, $0.taskID, $0.taskRunID].compactMap { $0 }.joined(separator: " "),
                 sessionID: $0.sessionID, usage: $0)
        }
        for item in lifecycle.items {
            records += item.timeline.map {
                Self(id: "task|" + item.id + "|" + $0.id, timestamp: $0.recordedAt, kind: .task,
                     text: item.taskID + " " + $0.taskRunID + " " + $0.title,
                     sessionID: $0.sessionID, localRef: $0.localRef)
            }
        }
        return records
    }
}

public struct InsightHistoryResult: Sendable {
    public let records: [InsightHistoryRecord]
    public let hasMore: Bool
    /// Totals cover the date range, regardless of search text or pagination.
    public let ledger: UsageLedger
    public let indexedThrough: Date?
    public let fullyIndexed: Bool
    public let warnings: [String]
}

/// A date-independent event index, separate from disposable scope snapshots.
/// Each refresh replaces its half-open window atomically, including deletions.
public actor InsightHistoryStore {
    public static let shared = InsightHistoryStore(url: CoachingQueryStore.defaultURL.deletingLastPathComponent()
        .appendingPathComponent("insight-history-v1.sqlite"))
    private let database: HistoryDatabase?
    public init(url: URL) { database = try? HistoryDatabase(url: url) }

    public func replace(project: String, range: Range<Date>, records: [InsightHistoryRecord],
                        warnings: [String] = [], capturedAt: Date = Date()) throws {
        guard let database else { throw HistoryError.unavailable }
        try Task.checkCancellation()
        try database.replace(project: project, range: range, records: records, warnings: warnings, capturedAt: capturedAt)
    }

    public func invalidate(project: String) throws {
        guard let database else { throw HistoryError.unavailable }
        try database.invalidate(project: project)
    }

    public func query(project: String, range: Range<Date>, search: String = "", limit: Int = 100,
                      offset: Int = 0) throws -> InsightHistoryResult {
        guard let database else { throw HistoryError.unavailable }
        return try database.query(project: project, range: range, search: search,
                                  limit: min(500, max(1, limit)), offset: max(0, offset))
    }
}

private enum HistoryError: LocalizedError {
    case unavailable, invalid, stale
    var errorDescription: String? {
        switch self {
        case .unavailable: return "Không đọc/ghi được chỉ mục lịch sử cục bộ. Log nguồn vẫn giữ nguyên."
        case .stale: return "Có lần cập nhật lịch sử mới hơn; bỏ qua kết quả đọc cũ."
        case .invalid: return "Bản ghi lịch sử không hợp lệ; lần cập nhật đã được hủy."
        }
    }
}

private final class HistoryDatabase: @unchecked Sendable {
    private var db: OpaquePointer?
    private let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
    init(url: URL) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true,
                                                attributes: [.posixPermissions: 0o700])
        guard sqlite3_open_v2(url.path, &db, SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE | SQLITE_OPEN_FULLMUTEX, nil) == SQLITE_OK else {
            sqlite3_close(db); db = nil; throw HistoryError.unavailable
        }
        do {
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
            sqlite3_busy_timeout(db, 1000)
            try execute("PRAGMA journal_mode=WAL")
            try execute("CREATE TABLE IF NOT EXISTS events (rowid INTEGER PRIMARY KEY, project TEXT NOT NULL, id TEXT NOT NULL, time REAL NOT NULL, kind TEXT NOT NULL, text TEXT NOT NULL, payload BLOB NOT NULL, UNIQUE(project,id))")
            try execute("CREATE INDEX IF NOT EXISTS events_range ON events(project,time,id)")
            try execute("CREATE VIRTUAL TABLE IF NOT EXISTS search USING fts5(text, content='events', content_rowid='rowid', tokenize='unicode61 remove_diacritics 2')")
            try execute("CREATE TRIGGER IF NOT EXISTS events_insert AFTER INSERT ON events BEGIN INSERT INTO search(rowid,text) VALUES(new.rowid,new.text); END")
            try execute("CREATE TRIGGER IF NOT EXISTS events_delete AFTER DELETE ON events BEGIN INSERT INTO search(search,rowid,text) VALUES('delete',old.rowid,old.text); END")
            try execute("CREATE TRIGGER IF NOT EXISTS events_update AFTER UPDATE ON events BEGIN INSERT INTO search(search,rowid,text) VALUES('delete',old.rowid,old.text); INSERT INTO search(rowid,text) VALUES(new.rowid,new.text); END")
            try execute("CREATE TABLE IF NOT EXISTS coverage (project TEXT NOT NULL, start REAL NOT NULL, end REAL NOT NULL, captured REAL NOT NULL, warnings BLOB NOT NULL)")
            try execute("CREATE INDEX IF NOT EXISTS coverage_range ON coverage(project,start,end)")
        } catch { sqlite3_close(db); db = nil; throw error }
    }
    deinit { sqlite3_close(db) }

    private func execute(_ sql: String) throws {
        guard sqlite3_exec(db, sql, nil, nil, nil) == SQLITE_OK else { throw HistoryError.unavailable }
    }
    private func statement(_ sql: String) throws -> OpaquePointer {
        var value: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &value, nil) == SQLITE_OK, let value else { throw HistoryError.unavailable }
        return value
    }
    private func bind(_ value: String, _ index: Int32, _ stmt: OpaquePointer) { sqlite3_bind_text(stmt, index, value, -1, transient) }
    private func bind(_ data: Data, _ index: Int32, _ stmt: OpaquePointer) {
        _ = data.withUnsafeBytes { sqlite3_bind_blob(stmt, index, $0.baseAddress, Int32(data.count), transient) }
    }
    private func data(_ stmt: OpaquePointer, _ index: Int32) -> Data {
        guard let bytes = sqlite3_column_blob(stmt, index) else { return Data() }
        return Data(bytes: bytes, count: Int(sqlite3_column_bytes(stmt, index)))
    }
    private func done(_ stmt: OpaquePointer) throws {
        guard sqlite3_step(stmt) == SQLITE_DONE else { throw HistoryError.unavailable }
    }

    func invalidate(project: String) throws {
        try execute("BEGIN IMMEDIATE")
        do {
            for table in ["events", "coverage"] {
                let stmt = try statement("DELETE FROM " + table + " WHERE project=?")
                defer { sqlite3_finalize(stmt) }
                bind(project, 1, stmt); try done(stmt)
            }
            try execute("COMMIT")
        } catch { try? execute("ROLLBACK"); throw error }
    }

    func replace(project: String, range: Range<Date>, records: [InsightHistoryRecord], warnings: [String], capturedAt: Date) throws {
        guard !project.isEmpty, !project.contains("\0"), capturedAt.timeIntervalSince1970.isFinite,
              range.lowerBound.timeIntervalSince1970.isFinite, range.upperBound.timeIntervalSince1970.isFinite,
              records.allSatisfy({ record in range.contains(record.timestamp) && !record.id.isEmpty && !record.id.contains("\0")
                  && record.text.utf8.count <= 1_048_576 && (record.kind == .usage) == (record.usage != nil)
                  && (record.usage.map { $0.timestamp == record.timestamp && $0.tokens.isValid } ?? true) }) else { throw HistoryError.invalid }
        try execute("BEGIN IMMEDIATE")
        do {
            // Preserve coverage outside the refreshed interval; old warnings do
            // not contaminate a newly repaired interval.
            let old = try coverage(project: project, range: range)
            guard old.allSatisfy({ $0.captured <= capturedAt }) else { throw HistoryError.stale }
            let eraseCoverage = try statement("DELETE FROM coverage WHERE project=? AND start<? AND end>?")
            defer { sqlite3_finalize(eraseCoverage) }
            bind(project, 1, eraseCoverage); sqlite3_bind_double(eraseCoverage, 2, range.upperBound.timeIntervalSince1970)
            sqlite3_bind_double(eraseCoverage, 3, range.lowerBound.timeIntervalSince1970); try done(eraseCoverage)
            for entry in old {
                if entry.start < range.lowerBound { try addCoverage(project, entry.start..<range.lowerBound, entry.captured, entry.warnings) }
                if entry.end > range.upperBound { try addCoverage(project, range.upperBound..<entry.end, entry.captured, entry.warnings) }
            }
            let erase = try statement("DELETE FROM events WHERE project=? AND time>=? AND time<?")
            defer { sqlite3_finalize(erase) }
            bind(project, 1, erase); sqlite3_bind_double(erase, 2, range.lowerBound.timeIntervalSince1970)
            sqlite3_bind_double(erase, 3, range.upperBound.timeIntervalSince1970); try done(erase)
            let insert = try statement("INSERT INTO events(project,id,time,kind,text,payload) VALUES(?,?,?,?,?,?) ON CONFLICT(project,id) DO UPDATE SET time=excluded.time,kind=excluded.kind,text=excluded.text,payload=excluded.payload")
            defer { sqlite3_finalize(insert) }
            for record in records {
                try Task.checkCancellation()
                sqlite3_reset(insert); sqlite3_clear_bindings(insert)
                bind(project, 1, insert); bind(record.id, 2, insert)
                sqlite3_bind_double(insert, 3, record.timestamp.timeIntervalSince1970)
                bind(record.kind.rawValue, 4, insert); bind(record.text, 5, insert)
                bind(try JSONEncoder().encode(record), 6, insert); try done(insert)
            }
            try addCoverage(project, range, capturedAt, warnings)
            try Task.checkCancellation()
            try execute("COMMIT")
        } catch { try? execute("ROLLBACK"); throw error }
    }
    private struct Coverage { let start: Date; let end: Date; let captured: Date; let warnings: [String] }
    private func coverage(project: String, range: Range<Date>) throws -> [Coverage] {
        let stmt = try statement("SELECT start,end,captured,warnings FROM coverage WHERE project=? AND start<? AND end>? ORDER BY start")
        defer { sqlite3_finalize(stmt) }
        bind(project, 1, stmt); sqlite3_bind_double(stmt, 2, range.upperBound.timeIntervalSince1970)
        sqlite3_bind_double(stmt, 3, range.lowerBound.timeIntervalSince1970)
        var rows: [Coverage] = []
        while true {
            let code = sqlite3_step(stmt)
            if code == SQLITE_DONE { break }
            guard code == SQLITE_ROW else { throw HistoryError.unavailable }
            rows.append(Coverage(start: Date(timeIntervalSince1970: sqlite3_column_double(stmt, 0)),
                end: Date(timeIntervalSince1970: sqlite3_column_double(stmt, 1)),
                captured: Date(timeIntervalSince1970: sqlite3_column_double(stmt, 2)),
                warnings: try JSONDecoder().decode([String].self, from: data(stmt, 3))))
        }
        return rows
    }
    private func addCoverage(_ project: String, _ range: Range<Date>, _ captured: Date, _ warnings: [String]) throws {
        let stmt = try statement("INSERT INTO coverage VALUES(?,?,?,?,?)")
        defer { sqlite3_finalize(stmt) }
        bind(project, 1, stmt); sqlite3_bind_double(stmt, 2, range.lowerBound.timeIntervalSince1970)
        sqlite3_bind_double(stmt, 3, range.upperBound.timeIntervalSince1970)
        sqlite3_bind_double(stmt, 4, captured.timeIntervalSince1970); bind(try JSONEncoder().encode(warnings), 5, stmt)
        try done(stmt)
    }
    func query(project: String, range: Range<Date>, search: String, limit: Int, offset: Int) throws -> InsightHistoryResult {
        try execute("BEGIN")
        defer { try? execute("ROLLBACK") }
        let intervals = try coverage(project: project, range: range)
        var through = range.lowerBound
        for entry in intervals where entry.start <= through { through = max(through, entry.end) }
        let terms = search.prefix(4096).split(whereSeparator: { $0.isWhitespace }).map { "\"" + $0.replacingOccurrences(of: "\"", with: "\"\"") + "\"" }
        let filter = terms.isEmpty ? "" : " AND e.rowid IN (SELECT rowid FROM search WHERE search MATCH ?)"
        let stmt = try statement("SELECT e.payload FROM events e WHERE e.project=? AND e.time>=? AND e.time<?" + filter + " ORDER BY e.time DESC,e.id LIMIT ? OFFSET ?")
        defer { sqlite3_finalize(stmt) }
        bind(project, 1, stmt); sqlite3_bind_double(stmt, 2, range.lowerBound.timeIntervalSince1970)
        sqlite3_bind_double(stmt, 3, range.upperBound.timeIntervalSince1970)
        var next: Int32 = 4
        if !terms.isEmpty { bind(terms.joined(separator: " AND "), next, stmt); next += 1 }
        sqlite3_bind_int64(stmt, next, Int64(limit + 1)); sqlite3_bind_int64(stmt, next + 1, Int64(offset))
        var rows: [InsightHistoryRecord] = []
        while true {
            let code = sqlite3_step(stmt)
            if code == SQLITE_DONE { break }
            guard code == SQLITE_ROW else { throw HistoryError.unavailable }
            rows.append(try JSONDecoder().decode(InsightHistoryRecord.self, from: data(stmt, 0)))
        }
        let usage = try statement("SELECT payload FROM events WHERE project=? AND time>=? AND time<? AND kind='usage'")
        defer { sqlite3_finalize(usage) }
        bind(project, 1, usage); sqlite3_bind_double(usage, 2, range.lowerBound.timeIntervalSince1970)
        sqlite3_bind_double(usage, 3, range.upperBound.timeIntervalSince1970)
        var ledger = UsageLedger()
        while true {
            let code = sqlite3_step(usage)
            if code == SQLITE_DONE { break }
            guard code == SQLITE_ROW else { throw HistoryError.unavailable }
            if let entry = try JSONDecoder().decode(InsightHistoryRecord.self, from: data(usage, 0)).usage { ledger.upsert(entry) }
        }
        var warnings = Array(Set(intervals.flatMap(\.warnings) + ledger.warnings)).sorted()
        if through < range.upperBound { warnings.append("Có khoảng thời gian chưa được lập chỉ mục; kết quả không đại diện toàn bộ lịch sử.") }
        return InsightHistoryResult(records: Array(rows.prefix(limit)), hasMore: rows.count > limit,
            ledger: ledger, indexedThrough: intervals.map(\.captured).min(), fullyIndexed: through >= range.upperBound,
            warnings: warnings)
    }
}
