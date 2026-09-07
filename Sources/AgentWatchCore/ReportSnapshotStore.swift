import Foundation
import Darwin

/// Atomic local storage with an inter-process lock. Future delivery outboxes use
/// the same primitive so double clicks/restarts cannot silently duplicate work.
public struct ReportFileStore: Sendable {
    public let root: URL
    public init(root: URL) { self.root = root }
    public func transaction<T>(_ body: () throws -> T) throws -> T {
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let descriptor = open(root.appendingPathComponent(".lock").path, O_CREAT | O_RDWR | O_NOFOLLOW, 0o600)
        guard descriptor >= 0 else { throw ReportValidationError.invalid("Không khóa được kho báo cáo.") }
        defer { flock(descriptor, LOCK_UN); close(descriptor) }
        guard flock(descriptor, LOCK_EX) == 0 else { throw ReportValidationError.invalid("Không khóa được kho báo cáo.") }
        return try body()
    }
    public func write(_ data: Data, to url: URL) throws {
        try data.write(to: url, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
        let handle = try FileHandle(forWritingTo: url); defer { try? handle.close() }
        try handle.synchronize()
        let directory = open(url.deletingLastPathComponent().path, O_RDONLY)
        if directory >= 0 { _ = fsync(directory); close(directory) }
    }
}

public struct ReportSnapshotStore: Sendable {
    public let files: ReportFileStore
    public init(root: URL) { files = ReportFileStore(root: root) }
    public static var local: Self {
        Self(root: URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("Library/Application Support/AgentWatch/reports"))
    }
    public func save(_ draft: DailyReportDraft, reviewedBy: String, now: Date = Date()) throws -> ReportSnapshot {
        try ReportValidator.validate(draft, forReview: true)
        guard reviewedBy == draft.employee.employeeID else { throw ReportValidationError.invalid("Người duyệt phải khớp hồ sơ nhân viên.") }
        return try files.transaction {
            let prior = try historyUnlocked().filter { $0.reportID == draft.reportID }
            let revision = (prior.map(\.revision).max() ?? 0) + 1
            let hash = try Self.contentHash(report: draft, revision: revision, generatedAt: now, reviewedBy: reviewedBy)
            let snapshot = ReportSnapshot(schemaVersion: 1, rendererVersion: "daily-v1", reportID: draft.reportID,
                                          revision: revision, generatedAt: now, reviewedBy: reviewedBy,
                                          report: draft, contentHash: hash)
            let url = files.root.appendingPathComponent(snapshot.id + ".json")
            guard !FileManager.default.fileExists(atPath: url.path) else { throw ReportValidationError.invalid("Phiên bản đã tồn tại; không ghi đè.") }
            let bytes = try ReportEncoding.encode(snapshot)
            try ReportSchema.validateSnapshot(bytes)
            try files.write(bytes, to: url)
            return snapshot
        }
    }
    public func history() throws -> [ReportSnapshot] { try files.transaction { try historyUnlocked() } }
    private func historyUnlocked() throws -> [ReportSnapshot] {
        let urls = try FileManager.default.contentsOfDirectory(at: files.root, includingPropertiesForKeys: nil)
        return try urls.filter { $0.pathExtension == "json" }.map { url in
            let data = try Data(contentsOf: url)
            try ReportSchema.validateSnapshot(data)
            let snapshot = try ReportEncoding.decode(ReportSnapshot.self, from: data)
            try Self.validate(snapshot)
            return snapshot
        }.sorted { $0.generatedAt > $1.generatedAt }
    }
    public static func validate(_ snapshot: ReportSnapshot) throws {
        try ReportSchema.validateSnapshot(ReportEncoding.encode(snapshot))
        guard snapshot.schemaVersion == 1, snapshot.rendererVersion == "daily-v1", snapshot.revision > 0,
              snapshot.reportID == snapshot.report.reportID, snapshot.reviewedBy == snapshot.report.employee.employeeID,
              try Self.contentHash(report: snapshot.report, revision: snapshot.revision, generatedAt: snapshot.generatedAt, reviewedBy: snapshot.reviewedBy) == snapshot.contentHash else {
            throw ReportValidationError.invalid("Báo cáo đã lưu không còn khớp nội dung được duyệt.")
        }
        try ReportValidator.validate(snapshot.report, forReview: true)
    }
    private struct Seal: Encodable {
        let schemaVersion = 1
        let rendererVersion = "daily-v1"
        let revision: Int
        let generatedAt: Date
        let reviewedBy: String
    }
    private static func contentHash(report: DailyReportDraft, revision: Int, generatedAt: Date, reviewedBy: String) throws -> String {
        var data = try ReportEncoding.encode(Seal(revision: revision, generatedAt: generatedAt, reviewedBy: reviewedBy))
        data.append(try ReportEncoding.encode(report)); return ReportEncoding.digest(data)
    }
}


public struct DailyReportDraftStore: Sendable {
    public let files: ReportFileStore
    public init(root: URL) { files = ReportFileStore(root: root) }
    public static var local: Self { Self(root: ReportSnapshotStore.local.files.root.appendingPathComponent("drafts")) }
    public func save(_ draft: DailyReportDraft) throws {
        try files.transaction { try files.write(ReportEncoding.encode(draft), to: files.root.appendingPathComponent("current.json")) }
    }
    public func load() throws -> DailyReportDraft? {
        try files.transaction {
            let url = files.root.appendingPathComponent("current.json")
            guard FileManager.default.fileExists(atPath: url.path) else { return nil }
            return try ReportEncoding.decode(DailyReportDraft.self, from: Data(contentsOf: url))
        }
    }
}
