import Foundation

public struct DriveDestination: Codable, Sendable, Equatable {
    public let accountKey: String
    public let folderID: String
    public let fileName: String
    public init(accountKey: String, folderID: String, fileName: String) {
        self.accountKey = accountKey; self.folderID = folderID; self.fileName = fileName
    }
    public var digest: String { ReportEncoding.digest((try? ReportEncoding.encode(self)) ?? Data()) }
}
public enum DriveUploadState: String, Codable, Sendable { case prepared, uploading, uploaded, failed, uncertain }
public struct DriveUploadApproval: Codable, Sendable, Equatable {
    public let approvedBy: String
    public let approvedAt: Date
    public let reportContentHash: String
    public let destinationHash: String
    public let payloadHash: String
    public let folderPermissionHash: String
}
public struct DriveUploadJob: Codable, Sendable, Equatable, Identifiable {
    public let id: String
    public let reportID: String
    public let revision: Int
    public let reportContentHash: String
    public let employeeID: String
    public let destination: DriveDestination
    public let payloadHash: String
    public let payloadBytes: Int
    public let createdAt: Date
    public var state: DriveUploadState
    public var approval: DriveUploadApproval?
    public var fileID: String?
    public var webViewLink: String?
    public var leaseOwner: String?
    public var leaseUntil: Date?
    public var attemptCount: Int
    public var lastError: String?
    public var retryNotBefore: Date? = nil
    public var organizationID: String? = nil
    public var reportTimeZone: String? = nil
}

public struct DriveUploadStore: Sendable {
    public let files: ReportFileStore
    public init(root: URL) { files = ReportFileStore(root: root) }
    public static var local: Self { Self(root: ReportSnapshotStore.local.files.root.appendingPathComponent("drive-outbox")) }
    public func prepare(snapshot: ReportSnapshot, destination: DriveDestination, payload: Data, now: Date = Date()) throws -> DriveUploadJob {
        try ReportSnapshotStore.validate(snapshot)
        guard payload.count <= 5_000_000 else { throw GoogleServiceError.unsupportedSize }
        guard !destination.accountKey.isEmpty, DriveAPI.validID(destination.folderID),
              !destination.fileName.isEmpty, !destination.fileName.contains("/"), !destination.fileName.contains("\n"),
              payload.count > 0, payload.count <= 5_000_000 else { throw GoogleServiceError.invalidConfiguration }
        let id = ReportEncoding.digest(Data("\(snapshot.id)|\(destination.digest)".utf8))
        return try files.transaction {
            if let old = try readUnlocked(id) {
                guard old.reportContentHash == snapshot.contentHash else { throw GoogleServiceError.storage("Nội dung report đã thay đổi; cần chốt phiên bản mới.") }
                return old // Preserve exact bytes, including original PDF metadata.
            }
            var job = DriveUploadJob(id: id, reportID: snapshot.reportID, revision: snapshot.revision, reportContentHash: snapshot.contentHash, employeeID: snapshot.report.employee.employeeID,
                                     destination: destination, payloadHash: ReportEncoding.digest(payload), payloadBytes: payload.count,
                                     createdAt: now, state: .prepared, approval: nil, fileID: nil, webViewLink: nil,
                                     leaseOwner: nil, leaseUntil: nil, attemptCount: 0, lastError: nil)
            job.organizationID = snapshot.report.employee.organizationID
            job.reportTimeZone = snapshot.report.period.timeZone
            try files.write(payload, to: payloadURL(id))
            try writeUnlocked(job)
            return job
        }
    }
    public func approve(jobID: String, approver: String, folderPermissionHash: String, expectedPayloadHash: String, now: Date = Date()) throws -> DriveUploadJob {
        try mutate(jobID) { job in
            guard approver == job.employeeID, !folderPermissionHash.isEmpty, expectedPayloadHash == job.payloadHash,
                  job.state != .uploading else { throw GoogleServiceError.invalidConfiguration }
            job.approval = DriveUploadApproval(approvedBy: approver, approvedAt: now, reportContentHash: job.reportContentHash,
                                               destinationHash: job.destination.digest, payloadHash: job.payloadHash, folderPermissionHash: folderPermissionHash)
        }
    }
    public func claim(jobID: String, owner: String, now: Date = Date()) throws -> DriveUploadJob {
        try mutate(jobID) { job in
            guard let approval = job.approval, approval.reportContentHash == job.reportContentHash,
                  approval.destinationHash == job.destination.digest, approval.payloadHash == job.payloadHash else { throw GoogleServiceError.permissionDenied }
            if job.state == .uploaded { return }
            if let retry = job.retryNotBefore, retry > now { throw GoogleServiceError.rateLimited }
            if let lease = job.leaseUntil, lease > now { throw GoogleServiceError.storage("Report đang được upload bởi một thao tác khác.") }
            job.state = .uploading; job.leaseOwner = owner; job.leaseUntil = now.addingTimeInterval(180)
            job.attemptCount += 1; job.lastError = nil; job.retryNotBefore = nil
        }
    }
    public func update(jobID: String, owner: String, _ body: (inout DriveUploadJob) throws -> Void) throws -> DriveUploadJob {
        try mutate(jobID) { job in
            guard job.leaseOwner == owner else { throw GoogleServiceError.storage("Quyền xử lý upload đã đổi; cần đọc lại trạng thái.") }
            try body(&job)
        }
    }
    public func read(_ id: String) throws -> DriveUploadJob? { try files.transaction { try readUnlocked(id) } }
    public func all() throws -> [DriveUploadJob] {
        try files.transaction {
            try FileManager.default.contentsOfDirectory(at: files.root, includingPropertiesForKeys: nil)
                .filter { $0.pathExtension == "json" }
                .compactMap { try readUnlocked($0.deletingPathExtension().lastPathComponent) }
                .sorted { $0.createdAt > $1.createdAt }
        }
    }
    public func payload(for job: DriveUploadJob) throws -> Data {
        guard job.id.range(of: "^[a-f0-9]{64}$", options: .regularExpression) != nil else { throw GoogleServiceError.invalidConfiguration }
        let data = try Data(contentsOf: payloadURL(job.id))
        guard data.count == job.payloadBytes, ReportEncoding.digest(data) == job.payloadHash else { throw GoogleServiceError.storage("File report chờ upload đã thay đổi; dừng gửi.") }
        return data
    }
    private func mutate(_ id: String, _ body: (inout DriveUploadJob) throws -> Void) throws -> DriveUploadJob {
        try files.transaction {
            guard var job = try readUnlocked(id) else { throw GoogleServiceError.notFound }
            try body(&job); try writeUnlocked(job); return job
        }
    }
    private func readUnlocked(_ id: String) throws -> DriveUploadJob? {
        guard id.range(of: "^[a-f0-9]{64}$", options: .regularExpression) != nil else { throw GoogleServiceError.invalidConfiguration }
        let url = files.root.appendingPathComponent(id + ".json")
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        let job = try ReportEncoding.decode(DriveUploadJob.self, from: Data(contentsOf: url))
        let expectedID = ReportEncoding.digest(Data("\(job.reportID)-r\(job.revision)|\(job.destination.digest)".utf8))
        guard job.id == id, expectedID == id, DriveAPI.validID(job.destination.folderID),
              job.fileID.map(DriveAPI.validID) ?? true else { throw GoogleServiceError.storage("Mã upload không khớp dữ liệu đã lưu.") }
        if job.state == .uploaded {
            guard let fileID = job.fileID, job.webViewLink == "https://drive.google.com/file/d/\(fileID)/view" else {
                throw GoogleServiceError.storage("Receipt Drive không hợp lệ.")
            }
        }
        return job
    }
    private func writeUnlocked(_ job: DriveUploadJob) throws { try files.write(ReportEncoding.encode(job), to: files.root.appendingPathComponent(job.id + ".json")) }
    private func payloadURL(_ id: String) -> URL { files.root.appendingPathComponent(id + ".pdf") }
}
