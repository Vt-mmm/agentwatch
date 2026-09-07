import Foundation

public enum ReportDeliveryChannel: String, Codable, Sendable, CaseIterable { case drive, gmail }
public enum ReportScheduleState: String, Codable, Sendable { case queued, running, complete, needsReview, missed, cancelled }
public struct ReportDeliverySchedule: Codable, Sendable, Equatable, Identifiable {
    public let id: String
    public let jobID: String
    public let channel: ReportDeliveryChannel
    public let employeeID: String
    public let accountKey: String
    public let payloadHash: String
    public let policyHash: String
    public let scheduledAt: Date
    public let expiresAt: Date
    public let timeZone: String
    public let approvedAt: Date
    public var state: ReportScheduleState
    public var startedAt: Date?
    public var finishedAt: Date?
    public var note: String?
}

public struct ReportDeliveryScheduleStore: Sendable {
    public let files: ReportFileStore
    public init(root: URL) { files = ReportFileStore(root: root) }
    public static var local: Self { Self(root: ReportSnapshotStore.local.files.root.appendingPathComponent("delivery-schedules")) }
    public func scheduleGmail(_ job: GmailOutboxJob, at date: Date, expiresAt: Date, timeZone: String, approvedBy: String,
                              policy: ReportTeamPolicyStore = .local, now: Date = Date()) throws -> ReportDeliverySchedule {
        try policy.checkGmail(organizationID: job.organizationID ?? "", employeeID: job.employeeID, destination: job.destination, scheduled: true, timeZone: job.reportTimeZone ?? "")
        guard [.prepared, .failed].contains(job.state), job.approval?.payloadHash == job.payloadHash,
              job.approval?.employeeID == job.employeeID else { throw GoogleServiceError.permissionDenied }
        return try create(jobID: job.id, channel: .gmail, employeeID: job.employeeID, accountKey: job.destination.accountKey,
                          payloadHash: job.payloadHash, policy: policy, at: date, expiresAt: expiresAt, timeZone: timeZone, approvedBy: approvedBy, now: now)
    }
    public func scheduleDrive(_ job: DriveUploadJob, at date: Date, expiresAt: Date, timeZone: String, approvedBy: String,
                              policy: ReportTeamPolicyStore = .local, now: Date = Date()) throws -> ReportDeliverySchedule {
        try policy.checkDrive(organizationID: job.organizationID ?? "", employeeID: job.employeeID, destination: job.destination, scheduled: true, timeZone: job.reportTimeZone ?? "")
        guard [.prepared, .failed, .uncertain].contains(job.state), job.approval?.payloadHash == job.payloadHash,
              job.approval?.approvedBy == job.employeeID else { throw GoogleServiceError.permissionDenied }
        return try create(jobID: job.id, channel: .drive, employeeID: job.employeeID, accountKey: job.destination.accountKey,
                          payloadHash: job.payloadHash, policy: policy, at: date, expiresAt: expiresAt, timeZone: timeZone, approvedBy: approvedBy, now: now)
    }
    private func create(jobID: String, channel: ReportDeliveryChannel, employeeID: String, accountKey: String, payloadHash: String,
                        policy: ReportTeamPolicyStore, at date: Date, expiresAt: Date, timeZone: String, approvedBy: String, now: Date) throws -> ReportDeliverySchedule {
        guard let policy = try policy.load(), approvedBy == employeeID, date > now, expiresAt > date,
              expiresAt.timeIntervalSince(date) <= 43_200, date < policy.expiresAt,
              TimeZone(identifier: timeZone) != nil, timeZone == policy.timeZone else { throw GoogleServiceError.invalidConfiguration }
        return try files.transaction {
            guard !(try allUnlocked()).contains(where: { $0.jobID == jobID && $0.channel == channel && [.queued, .running].contains($0.state) }) else { throw GoogleServiceError.conflict }
            let item = ReportDeliverySchedule(id: UUID().uuidString, jobID: jobID, channel: channel, employeeID: employeeID,
                accountKey: accountKey, payloadHash: payloadHash, policyHash: policy.digest, scheduledAt: date, expiresAt: expiresAt,
                timeZone: timeZone, approvedAt: now, state: .queued, startedAt: nil, finishedAt: nil, note: nil)
            try write(item); return item
        }
    }
    public func all() throws -> [ReportDeliverySchedule] { try files.transaction { try allUnlocked() } }
    /// A missed deadline or interrupted worker becomes visible review work.
    /// No catch-up send and no new report are invented on the next app launch.
    public func claimNext(now: Date = Date()) throws -> ReportDeliverySchedule? {
        try files.transaction {
            var claimed: ReportDeliverySchedule?
            for var item in try allUnlocked().sorted(by: { $0.scheduledAt < $1.scheduledAt }) {
                if item.state == .running, let started = item.startedAt, now.timeIntervalSince(started) > 180 {
                    item.state = .needsReview; item.note = "Ứng dụng dừng giữa lượt xử lý; cần đối chiếu trạng thái từng kênh."; item.finishedAt = now; try write(item)
                }
                guard item.state == .queued else { continue }
                if Self.milliseconds(now) >= Self.milliseconds(item.expiresAt) {
                    item.state = .missed; item.note = "Máy/ứng dụng không xử lý trong khoảng giờ đã duyệt; không tự gửi bù."; item.finishedAt = now; try write(item)
                } else if Self.milliseconds(item.scheduledAt) <= Self.milliseconds(now), claimed == nil {
                    item.state = .running; item.startedAt = now; try write(item); claimed = item
                }
            }
            return claimed
        }
    }
    public func finish(_ id: String, success: Bool, note: String, now: Date = Date()) throws {
        try files.transaction {
            guard var item = try allUnlocked().first(where: { $0.id == id }), item.state == .running else { throw GoogleServiceError.conflict }
            item.state = success ? .complete : .needsReview; item.finishedAt = now; item.note = ShareText.clean(note); try write(item)
        }
    }
    public func cancel(_ id: String, employeeID: String) throws {
        try files.transaction {
            guard var item = try allUnlocked().first(where: { $0.id == id }), [.queued, .needsReview, .missed].contains(item.state),
                  item.employeeID == employeeID else { throw GoogleServiceError.permissionDenied }
            item.state = .cancelled; item.finishedAt = Date(); item.note = "Nhân viên hủy lịch trên máy."; try write(item)
        }
    }
    private func allUnlocked() throws -> [ReportDeliverySchedule] {
        try FileManager.default.contentsOfDirectory(at: files.root, includingPropertiesForKeys: nil).filter { $0.pathExtension == "json" }.map {
            let item = try ReportEncoding.decode(ReportDeliverySchedule.self, from: Data(contentsOf: $0))
            guard UUID(uuidString: item.id) != nil, $0.lastPathComponent == item.id + ".json", item.expiresAt > item.scheduledAt else { throw GoogleServiceError.invalidConfiguration }; return item
        }
    }
    private func write(_ item: ReportDeliverySchedule) throws { try files.write(ReportEncoding.encode(item), to: files.root.appendingPathComponent(item.id + ".json")) }
    private static func milliseconds(_ date: Date) -> Int64 { Int64((date.timeIntervalSince1970 * 1000).rounded()) }
}
