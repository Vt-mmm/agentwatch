import Foundation
import CryptoKit
import SQLite3

struct CachedLogFile: Codable, Sendable {
    let stamp: LogFileStamp
    let result: CoachingFileResult
    let checkpoint: LogCheckpoint?
    var firstTimestamp: Date? = nil
    var lastTimestamp: Date? = nil
}

private struct IndexedLogBounds: Codable {
    let stamp: LogFileStamp
    let first: Date
    let last: Date
}

/// Empty fields mean all vendors/projects. Each group is independently
/// deduplicated; group totals must never be added together across overlapping IDs.
public struct CoachingAggregateKey: Codable, Hashable, Sendable {
    public let vendor: String
    public let project: String
    public init(vendor: String = "", project: String = "") {
        self.vendor = vendor; self.project = project
    }

    static func build(sessions: [SessionSummary], total: InventoryAggregate) -> [Self: InventoryAggregate] {
        var groups: [Self: [SessionSummary]] = [:]
        for session in sessions {
            let projects = Set([session.projectDisplay, session.displayTitle, session.sessionTitle ?? ""]).subtracting([""])
            for vendor in ["", session.source.vendor.label] {
                if !vendor.isEmpty { groups[Self(vendor: vendor), default: []].append(session) }
                for project in projects { groups[Self(vendor: vendor, project: project), default: []].append(session) }
            }
        }
        var result = groups.mapValues(SessionInventory.aggregate)
        result[Self()] = total
        return result
    }
}

/// Exact-scope materialized result, including totals calculated off the UI thread.
/// It is a dated snapshot, not a claim that source logs are still unchanged.
public struct CoachingSnapshot: Codable, Sendable {
    public let capturedAt: Date
    public let result: CoachingScanResult
    public let aggregate: InventoryAggregate
}

/// SQLite is a disposable local query cache. Source logs remain authoritative.
/// Actor isolation serializes writes; WAL allows other app/CLI readers to query.
public actor CoachingQueryStore {
    public static let shared = CoachingQueryStore(url: defaultURL)
    public static var defaultURL: URL {
        FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("com.vtamm.agentwatch/query-v1.sqlite")
    }
    // Bump when parsing, scoring, serialization or accounting semantics change.
    private static let version = "query-v2|" + Pricing.versionLabel
    private let database: QueryDatabase?
    private var scanGenerations: [String: UUID] = [:]
    private var files: [String: CachedLogFile] = [:]
    private var fileOrder: [String] = []
    private var snapshots: [String: CoachingSnapshot] = [:]

    /// Inject a temporary location for tests. Failure to open the cache falls
    /// back to full source scans, never an empty successful report.
    public init(url: URL) {
        database = QueryDatabase(url: url)
    }

    static func scopeKey(_ range: Range<Date>, roots: AgentLogRoots) -> String {
        key([String(range.lowerBound.timeIntervalSince1970), String(range.upperBound.timeIntervalSince1970),
             roots.claudeProjects, roots.claudeDesktop, roots.codexSessions, roots.codexArchived, roots.piSessions])
    }

    static func fileKey(_ file: URL, source: SessionSource, range: Range<Date>) -> String {
        key([file.path, source.rawValue, String(range.lowerBound.timeIntervalSince1970),
             String(range.upperBound.timeIntervalSince1970)])
    }

    private static func key(_ parts: [String]) -> String {
        let data = try! JSONEncoder().encode([version] + parts)
        return SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    func file(_ key: String) -> CachedLogFile? {
        if let hit = files[key] { return hit }
        guard let value = database?.load(CachedLogFile.self, category: "file", key: key) else { return nil }
        rememberFile(value, key: key)
        return value
    }

    func saveFile(_ value: CachedLogFile, key: String) {
        database?.save(value, category: "file", key: key)
        rememberFile(value, key: key)
    }

    private func rememberFile(_ value: CachedLogFile, key: String) {
        fileOrder.removeAll { $0 == key }
        fileOrder.append(key)
        files[key] = value
        // Checkpoint byte length dominates reducer state; leave room for decoded
        // prompt/ledger objects as well. Large entries remain disk-only.
        while files.count > 128 || files.values.reduce(0, { $0 + ($1.checkpoint?.state.count ?? 0) * 3
            + $1.result.prompts.reduce(0) { $0 + $1.text.utf8.count * 3 + 512 }
            + ($1.result.summary?.usageEntries?.count ?? 0) * 1024 }) > 32 * 1024 * 1024 {
            guard !fileOrder.isEmpty else { break }
            files.removeValue(forKey: fileOrder.removeFirst())
        }
    }

    func excludesRange(file: URL, stamp: LogFileStamp, range: Range<Date>) -> Bool {
        guard let bounds = database?.load(IndexedLogBounds.self, category: "bounds", key: Self.key([file.path])),
              bounds.stamp == stamp else { return false }
        return bounds.last < range.lowerBound || bounds.first >= range.upperBound
    }

    func saveBounds(file: URL, value: CachedLogFile) {
        guard let first = value.firstTimestamp, let last = value.lastTimestamp else { return }
        database?.save(IndexedLogBounds(stamp: value.stamp, first: first, last: last),
                       category: "bounds", key: Self.key([file.path]))
    }

    /// Does no source enumeration or log IO. Used on tab/scope selection only.
    public func snapshot(in range: Range<Date>, roots: AgentLogRoots = .current) -> CoachingSnapshot? {
        let key = Self.scopeKey(range, roots: roots)
        if let hit = snapshots[key] { return hit }
        guard let value = database?.load(CoachingSnapshot.self, category: "snapshot", key: key) else { return nil }
        remember(value, key: key)
        return value
    }

    func beginScan(in range: Range<Date>, roots: AgentLogRoots) -> UUID {
        let key = Self.scopeKey(range, roots: roots)
        let generation = UUID()
        scanGenerations[key] = generation
        return generation
    }

    func finishScan(in range: Range<Date>, roots: AgentLogRoots, generation: UUID) {
        let key = Self.scopeKey(range, roots: roots)
        if scanGenerations[key] == generation { scanGenerations.removeValue(forKey: key) }
    }

    func saveSnapshot(_ result: CoachingScanResult, range: Range<Date>, roots: AgentLogRoots, generation: UUID) {
        let key = Self.scopeKey(range, roots: roots)
        guard scanGenerations[key] == generation, !Task.isCancelled else { return }
        scanGenerations.removeValue(forKey: key)
        let value = CoachingSnapshot(capturedAt: Date(), result: result,
                                     aggregate: result.aggregate ?? SessionInventory.aggregate(result.sessions))
        database?.save(value, category: "snapshot", key: key)
        remember(value, key: key)
        database?.prune()
    }

    private func remember(_ value: CoachingSnapshot, key: String) {
        if snapshots.count >= 8, let oldest = snapshots.min(by: { $0.value.capturedAt < $1.value.capturedAt })?.key {
            snapshots.removeValue(forKey: oldest)
        }
        snapshots[key] = value
    }
}

/// Only accessed by CoachingQueryStore. Statements always bind user data.
private final class QueryDatabase: @unchecked Sendable {
    private var db: OpaquePointer?
    private let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

    init?(url: URL) {
        let fm = FileManager.default
        do {
            try fm.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true,
                                   attributes: [.posixPermissions: 0o700])
        } catch { return nil }
        guard sqlite3_open_v2(url.path, &db, SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE | SQLITE_OPEN_FULLMUTEX, nil) == SQLITE_OK else {
            sqlite3_close(db); db = nil; return nil
        }
        try? fm.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
        sqlite3_busy_timeout(db, 1000)
        guard execute("PRAGMA journal_mode=WAL"),
              execute("PRAGMA synchronous=NORMAL"),
              execute("CREATE TABLE IF NOT EXISTS query_cache (category TEXT NOT NULL, key TEXT NOT NULL, payload BLOB NOT NULL, accessed REAL NOT NULL, PRIMARY KEY(category,key))"),
              execute("CREATE INDEX IF NOT EXISTS query_cache_access ON query_cache(category,accessed)") else {
            sqlite3_close(db); db = nil; return nil
        }
    }

    deinit { sqlite3_close(db) }

    func load<T: Decodable>(_ type: T.Type, category: String, key: String) -> T? {
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(db, "SELECT payload FROM query_cache WHERE category=? AND key=?", -1, &statement, nil) == SQLITE_OK else { return nil }
        defer { sqlite3_finalize(statement) }
        sqlite3_bind_text(statement, 1, category, -1, transient)
        sqlite3_bind_text(statement, 2, key, -1, transient)
        guard sqlite3_step(statement) == SQLITE_ROW,
              let bytes = sqlite3_column_blob(statement, 0) else { return nil }
        let data = Data(bytes: bytes, count: Int(sqlite3_column_bytes(statement, 0)))
        return try? PropertyListDecoder().decode(type, from: data)
    }

    func save<T: Encodable>(_ value: T, category: String, key: String) {
        guard let data = IncrementalLogInput.encode(value), data.count <= 64 * 1024 * 1024 else { return }
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(db, "INSERT OR REPLACE INTO query_cache VALUES (?,?,?,?)", -1, &statement, nil) == SQLITE_OK else { return }
        defer { sqlite3_finalize(statement) }
        sqlite3_bind_text(statement, 1, category, -1, transient)
        sqlite3_bind_text(statement, 2, key, -1, transient)
        _ = data.withUnsafeBytes { sqlite3_bind_blob(statement, 3, $0.baseAddress, Int32(data.count), transient) }
        sqlite3_bind_double(statement, 4, Date().timeIntervalSince1970)
        _ = sqlite3_step(statement)
    }

    func prune() {
        // At most 24 scopes, 4,000 per-file scopes and 30 days of cache data.
        // Bound logical payload to 256 MiB. Freed pages are reused by SQLite.
        execute("DELETE FROM query_cache WHERE accessed < strftime('%s','now') - 2592000")
        execute("DELETE FROM query_cache WHERE category='snapshot' AND key NOT IN (SELECT key FROM query_cache WHERE category='snapshot' ORDER BY accessed DESC LIMIT 24)")
        execute("DELETE FROM query_cache WHERE category='file' AND key NOT IN (SELECT key FROM query_cache WHERE category='file' ORDER BY accessed DESC LIMIT 4000)")
        execute("DELETE FROM query_cache WHERE rowid IN (SELECT rowid FROM (SELECT rowid, SUM(length(payload)) OVER (ORDER BY accessed DESC, rowid DESC) AS bytes FROM query_cache) WHERE bytes > 268435456)")
    }

    @discardableResult private func execute(_ sql: String) -> Bool {
        sqlite3_exec(db, sql, nil, nil, nil) == SQLITE_OK
    }
}
