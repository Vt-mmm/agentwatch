import Foundation

public enum GmailDeliveryState: String, Codable, Sendable {
    case prepared, sending, accepted, failed, uncertain, manuallyConfirmed
    public var label: String {
        switch self {
        case .prepared: "Chờ duyệt gửi"
        case .sending: "Đang gửi yêu cầu"
        case .accepted: "Gmail đã nhận yêu cầu"
        case .failed: "Yêu cầu bị từ chối"
        case .uncertain: "Chưa rõ đã gửi — cần đối chiếu"
        case .manuallyConfirmed: "Người dùng xác nhận đã thấy trong Sent"
        }
    }
}
public struct GmailApproval: Codable, Sendable, Equatable {
    public let employeeID: String
    public let at: Date
    public let contentHash: String
    public let destinationHash: String
    public let payloadHash: String
}
public struct GmailAttempt: Codable, Sendable, Equatable {
    public let id: String
    public let startedAt: Date
    public var finishedAt: Date?
    public var outcome: String?
}
public struct GmailReconciliation: Codable, Sendable, Equatable {
    public let employeeID: String
    public let at: Date
    public let observedInSent: Bool
    public let note: String
}
public struct GmailOutboxJob: Codable, Sendable, Equatable, Identifiable {
    public let id: String
    public let reportID: String
    public let revision: Int
    public let contentHash: String
    public let employeeID: String
    public let destination: ReportMailDestination
    public let messageID: String
    public let payloadHash: String
    public let pdfHash: String
    public var previewText: String
    public let createdAt: Date
    public var state: GmailDeliveryState
    public var approval: GmailApproval?
    public var attempts: [GmailAttempt]
    public var reconciliations: [GmailReconciliation]
    public var leaseUntil: Date?
    public var gmailMessageID: String?
    public var gmailThreadID: String?
    public var lastError: String?
    public var retryNotBefore: Date?
    public var organizationID: String? = nil
    public var reportTimeZone: String? = nil
}

public struct GmailOutboxStore: Sendable {
    public let files: ReportFileStore
    public init(root: URL) { files = ReportFileStore(root: root) }
    public static var local: Self { Self(root: ReportSnapshotStore.local.files.root.appendingPathComponent("gmail-outbox")) }
    public func prepare(snapshot: ReportSnapshot, destination: ReportMailDestination, now: Date = Date()) throws -> GmailOutboxJob {
        try ReportSnapshotStore.validate(snapshot); try destination.validate()
        let id = Self.jobID(reportID: snapshot.reportID, revision: snapshot.revision, destination: destination)
        return try files.transaction {
            if let old = try readUnlocked(id) {
                guard old.contentHash == snapshot.contentHash else { throw GoogleServiceError.conflict }
                return old
            }
            let payload = try ReportMailRenderer.render(snapshot: snapshot, destination: destination, now: now)
            var job = GmailOutboxJob(id: id, reportID: snapshot.reportID, revision: snapshot.revision,
                                    contentHash: snapshot.contentHash, employeeID: snapshot.report.employee.employeeID,
                                    destination: destination, messageID: payload.messageID, payloadHash: ReportEncoding.digest(payload.mime),
                                    pdfHash: ReportEncoding.digest(payload.pdf), previewText: payload.text, createdAt: now,
                                    state: .prepared, approval: nil, attempts: [], reconciliations: [], leaseUntil: nil,
                                    gmailMessageID: nil, gmailThreadID: nil, lastError: nil, retryNotBefore: nil)
            job.organizationID = snapshot.report.employee.organizationID
            job.reportTimeZone = snapshot.report.period.timeZone
            try files.write(payload.mime, to: url(id, "eml")); try files.write(payload.pdf, to: url(id, "pdf"))
            try writeUnlocked(job); return job
        }
    }
    public func approve(_ id: String, employeeID: String, expectedPayloadHash: String, now: Date = Date()) throws -> GmailOutboxJob {
        try mutate(id) { job in
            guard [.prepared, .failed].contains(job.state), employeeID == job.employeeID,
                  expectedPayloadHash == job.payloadHash else { throw GoogleServiceError.permissionDenied }
            job.approval = GmailApproval(employeeID: employeeID, at: now, contentHash: job.contentHash,
                                         destinationHash: job.destination.digest, payloadHash: job.payloadHash)
        }
    }
    /// Claim writes 'sending' before the HTTP call. An abandoned claim is
    /// uncertain even if the crash happened before the socket was opened.
    public func claim(_ id: String, owner: String, now: Date = Date()) throws -> GmailOutboxJob {
        try files.transaction {
            guard var job = try readUnlocked(id) else { throw GoogleServiceError.notFound }
            if job.state == .sending, (job.leaseUntil ?? .distantPast) <= now {
                job.state = .uncertain; job.leaseUntil = nil; job.lastError = GoogleServiceError.uncertain.localizedDescription
                if !job.attempts.isEmpty { job.attempts[job.attempts.count - 1].outcome = "abandoned" }
                try writeUnlocked(job)
            }
            if [.accepted, .manuallyConfirmed].contains(job.state) { return job }
            guard [.prepared, .failed].contains(job.state) else { throw GoogleServiceError.uncertain }
            guard let approval = job.approval, approval.employeeID == job.employeeID,
                  approval.contentHash == job.contentHash, approval.destinationHash == job.destination.digest,
                  approval.payloadHash == job.payloadHash else { throw GoogleServiceError.permissionDenied }
            if let retry = job.retryNotBefore, retry > now { throw GoogleServiceError.rateLimited }
            _ = try payload(for: job); _ = try pdf(for: job)
            job.state = .sending; job.leaseUntil = now.addingTimeInterval(180); job.retryNotBefore = nil; job.lastError = nil
            job.attempts.append(GmailAttempt(id: owner, startedAt: now, finishedAt: nil, outcome: nil))
            try writeUnlocked(job); return job
        }
    }
    public func finish(_ id: String, owner: String, state: GmailDeliveryState, messageID: String? = nil,
                       threadID: String? = nil, error: String? = nil, retryAt: Date? = nil, now: Date = Date()) throws -> GmailOutboxJob {
        try mutate(id) { job in
            guard job.attempts.last?.id == owner, job.state == .sending,
                  [.accepted, .failed, .uncertain].contains(state), state != .accepted || Self.validReceiptID(messageID) else {
                throw GoogleServiceError.storage("Trạng thái gửi đã thay đổi; cần đọc lại hộp thư đi.")
            }
            job.state = state; job.gmailMessageID = messageID; job.gmailThreadID = threadID; job.lastError = error
            job.retryNotBefore = retryAt; job.leaseUntil = nil
            job.attempts[job.attempts.count - 1].finishedAt = now; job.attempts[job.attempts.count - 1].outcome = state.rawValue
        }
    }
    public func reconcile(_ id: String, employeeID: String, observedInSent: Bool, acceptsDuplicateRisk: Bool,
                          note: String, now: Date = Date()) throws -> GmailOutboxJob {
        try mutate(id) { job in
            if job.state == .sending, (job.leaseUntil ?? .distantPast) <= now { job.state = .uncertain; job.leaseUntil = nil }
            guard job.state == .uncertain, employeeID == job.employeeID,
                  !note.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                  observedInSent || acceptsDuplicateRisk else { throw GoogleServiceError.permissionDenied }
            job.reconciliations.append(GmailReconciliation(employeeID: employeeID, at: now, observedInSent: observedInSent, note: ShareText.clean(note)))
            job.state = observedInSent ? .manuallyConfirmed : .prepared
            job.approval = nil; job.lastError = nil
            // Stable Message-ID assists manual search; Gmail provides no
            // guaranteed idempotency key. Explicit retry can still duplicate.
        }
    }
    public func read(_ id: String) throws -> GmailOutboxJob? { try files.transaction { try readUnlocked(id) } }
    public func all() throws -> [GmailOutboxJob] {
        try files.transaction {
            try FileManager.default.contentsOfDirectory(at: files.root, includingPropertiesForKeys: nil)
                .filter { $0.pathExtension == "json" }.compactMap { try readUnlocked($0.deletingPathExtension().lastPathComponent) }
                .sorted { $0.createdAt > $1.createdAt }
        }
    }
    public func payload(for job: GmailOutboxJob) throws -> Data { try checkedData(job, extension: "eml", hash: job.payloadHash) }
    public func pdf(for job: GmailOutboxJob) throws -> Data { try checkedData(job, extension: "pdf", hash: job.pdfHash) }
    public func purgeCompletedPreview(_ id: String, expectedFileHash: String) throws {
        try files.transaction {
            guard var job = try readUnlocked(id), [.accepted, .manuallyConfirmed].contains(job.state),
                  ReportEncoding.digest(try Data(contentsOf: url(id, "json"))) == expectedFileHash else { throw GoogleServiceError.conflict }
            job.previewText = "Nội dung đã dọn theo thời hạn lưu; receipt được giữ lại."
            try writeUnlocked(job)
        }
    }
    private func checkedData(_ job: GmailOutboxJob, extension ext: String, hash: String) throws -> Data {
        guard Self.validKey(job.id) else { throw GoogleServiceError.invalidConfiguration }
        let data = try Data(contentsOf: url(job.id, ext))
        guard ReportEncoding.digest(data) == hash else { throw GoogleServiceError.storage("Nội dung email chờ gửi đã thay đổi; dừng gửi.") }
        return data
    }
    private func mutate(_ id: String, _ body: (inout GmailOutboxJob) throws -> Void) throws -> GmailOutboxJob {
        try files.transaction {
            guard var job = try readUnlocked(id) else { throw GoogleServiceError.notFound }
            try body(&job); try writeUnlocked(job); return job
        }
    }
    private func readUnlocked(_ id: String) throws -> GmailOutboxJob? {
        guard Self.validKey(id) else { throw GoogleServiceError.invalidConfiguration }
        guard FileManager.default.fileExists(atPath: url(id, "json").path) else { return nil }
        let job = try ReportEncoding.decode(GmailOutboxJob.self, from: Data(contentsOf: url(id, "json")))
        try job.destination.validate()
        guard job.id == id, Self.jobID(reportID: job.reportID, revision: job.revision, destination: job.destination) == id,
              job.state != .accepted || Self.validReceiptID(job.gmailMessageID) else { throw GoogleServiceError.invalidResponse }
        return job
    }
    private func writeUnlocked(_ job: GmailOutboxJob) throws { try files.write(ReportEncoding.encode(job), to: url(job.id, "json")) }
    private func url(_ id: String, _ ext: String) -> URL { files.root.appendingPathComponent(id + "." + ext) }
    private static func jobID(reportID: String, revision: Int, destination: ReportMailDestination) -> String {
        ReportEncoding.digest(Data("\(reportID)-r\(revision)|gmail|\(destination.digest)".utf8))
    }
    private static func validKey(_ value: String) -> Bool { value.range(of: "^[a-f0-9]{64}$", options: .regularExpression) != nil }
    static func validReceiptID(_ value: String?) -> Bool { value?.range(of: "^[A-Za-z0-9_-]{1,256}$", options: .regularExpression) != nil }
}
