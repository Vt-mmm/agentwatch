import Foundation
import Darwin

public struct TeamDeliveryObservation: Sendable, Identifiable {
    public let id: String
    public let channel: String
    public let state: String
    public let needsAttention: Bool

    public static func matching(_ snapshot: ReportSnapshot, gmail: [GmailOutboxJob], drive: [DriveUploadJob]) -> [Self] {
        let employee = snapshot.report.employee
        var rows = gmail.filter { $0.organizationID == employee.organizationID && $0.employeeID == employee.employeeID
            && $0.reportID == snapshot.reportID && $0.revision == snapshot.revision && $0.contentHash == snapshot.contentHash }.map {
                Self(id: "gmail|" + $0.id, channel: "Gmail", state: $0.state.label, needsAttention: [.failed, .uncertain].contains($0.state))
            }
        rows += drive.filter { $0.organizationID == employee.organizationID && $0.employeeID == employee.employeeID
            && $0.reportID == snapshot.reportID && $0.revision == snapshot.revision && $0.reportContentHash == snapshot.contentHash }.map {
                Self(id: "drive|" + $0.id, channel: "Drive", state: $0.state.rawValue, needsAttention: [.failed, .uncertain].contains($0.state))
            }
        return rows.sorted { $0.id < $1.id }
    }
}

public struct TeamReportMember: Sendable, Identifiable {
    public let employeeID: String
    public let snapshot: ReportSnapshot?
    public var deliveries: [TeamDeliveryObservation] = []
    public var id: String { employeeID }
    public var outstanding: [ReportWorkItem] { snapshot?.report.workItems.filter { ![.completed, .cancelled].contains($0.status) } ?? [] }
    public var needsHelp: [ReportWorkItem] { outstanding.filter { $0.status == .blocked || !$0.blockers.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty } }
    public var partialDay: Bool { snapshot.map { $0.report.period.cutoff < $0.report.period.end } ?? false }
}

public struct TeamReportOverview: Sendable {
    public let organizationID: String
    public let day: Date
    public let checkedAt: Date
    public let members: [TeamReportMember]
    public let warnings: [String]
}

public struct TeamReportImportResult: Sendable {
    public let imported: Int
    public let unchanged: Int
    public let rejected: [String]
}

/// Local reviewed-report inbox. Policy ownership is an application-level guard
/// under the trusted OS user, not authentication or a remote multi-tenant ACL.
/// Content seals detect changes; they are not employee digital signatures.
public struct TeamReportInbox: Sendable {
    private let root: URL
    private let policies: ReportTeamPolicyStore
    private let gmail: GmailOutboxStore?
    private let drive: DriveUploadStore?
    public init(root: URL, policies: ReportTeamPolicyStore, gmail: GmailOutboxStore? = nil, drive: DriveUploadStore? = nil) {
        self.root = root; self.policies = policies; self.gmail = gmail; self.drive = drive
    }
    public static var local: Self { Self(root: ReportSnapshotStore.local.files.root.appendingPathComponent("team-inbox"), policies: .local, gmail: .local, drive: .local) }

    private func access(employeeID: String, now: Date) throws -> ReportTeamPolicy {
        guard let policy = try policies.load() else { throw ReportValidationError.invalid("Cần chính sách nhóm đã được cài đặt trước khi xem hoặc nhập báo cáo nhóm.") }
        try policy.validate()
        guard employeeID == policy.owner, policy.effectiveFrom <= now, now < policy.expiresAt else {
            throw ReportValidationError.invalid("Chỉ chủ chính sách nhóm còn hiệu lực được thao tác kho tổng hợp cục bộ.")
        }
        return policy
    }
    private func files(_ policy: ReportTeamPolicy) -> ReportFileStore {
        let key = ReportEncoding.digest(Data(policy.organizationID.utf8))
        return ReportFileStore(root: root.appendingPathComponent(key))
    }
    private func validate(_ snapshot: ReportSnapshot, policy: ReportTeamPolicy) throws {
        try ReportSnapshotStore.validate(snapshot)
        guard snapshot.report.employee.organizationID == policy.organizationID,
              policy.employees.contains(where: { $0.employeeID == snapshot.report.employee.employeeID }),
              snapshot.report.period.timeZone == policy.timeZone else {
            throw ReportValidationError.invalid("Báo cáo ngoài tổ chức/danh sách thành viên hoặc khác múi giờ của nhóm.")
        }
    }
    /// Idempotent by reviewed report ID/revision/hash. Conflicting same-revision
    /// content is rejected rather than silently replacing an accepted version.
    @discardableResult public func importReport(_ data: Data, employeeID: String, now: Date = Date()) throws -> Bool {
        guard data.count <= 16 * 1024 * 1024 else { throw ReportValidationError.invalid("Báo cáo vượt giới hạn 16 MiB.") }
        try ReportSchema.validateSnapshot(data)
        let snapshot = try ReportEncoding.decode(ReportSnapshot.self, from: data)
        let policy = try access(employeeID: employeeID, now: now)
        try validate(snapshot, policy: policy)
        let store = files(policy)
        return try store.transaction {
            let current = try access(employeeID: employeeID, now: now)
            guard current.digest == policy.digest else { throw ReportValidationError.invalid("Chính sách vừa đổi; cần đọc lại.") }
            let target = store.root.appendingPathComponent(snapshot.id + ".json")
            if FileManager.default.fileExists(atPath: target.path) {
                let existing = try ReportEncoding.decode(ReportSnapshot.self, from: boundedRead(target))
                try validate(existing, policy: current)
                guard existing.contentHash == snapshot.contentHash else { throw ReportValidationError.invalid("Cùng mã và phiên bản báo cáo nhưng khác nội dung; cần người phụ trách đối chiếu.") }
                return false
            }
            try store.write(ReportEncoding.encode(snapshot), to: target)
            return true
        }
    }
    /// One explicitly selected folder, no recursion, symlinks, network or sends.
    /// Each file is independently validated; failures remain visible.
    public func importFolder(_ folder: URL, employeeID: String, now: Date = Date()) throws -> TeamReportImportResult {
        _ = try access(employeeID: employeeID, now: now)
        let urls = try FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: [.isRegularFileKey])
            .filter { $0.pathExtension.lowercased() == "json" }.sorted { $0.lastPathComponent < $1.lastPathComponent }
        var imported = 0, unchanged = 0, rejected: [String] = []
        if urls.count > 500 { rejected.append("Thư mục có hơn 500 tệp JSON; chỉ xử lý 500 tệp đầu.") }
        for url in urls.prefix(500) {
            if Task.isCancelled { rejected.append("Đã dừng nhập thư mục; các tệp đã nhập vẫn giữ nguyên."); break }
            do {
                if try importReport(boundedRead(url), employeeID: employeeID, now: now) { imported += 1 }
                else { unchanged += 1 }
            } catch { rejected.append(url.lastPathComponent + ": " + error.localizedDescription) }
        }
        return TeamReportImportResult(imported: imported, unchanged: unchanged, rejected: rejected)
    }
    public func overview(employeeID: String, day: Date, now: Date = Date()) throws -> TeamReportOverview {
        let policy = try access(employeeID: employeeID, now: now)
        var calendar = Calendar(identifier: .gregorian); calendar.timeZone = TimeZone(identifier: policy.timeZone)!
        let start = calendar.startOfDay(for: day)
        let store = files(policy)
        return try store.transaction {
            let current = try access(employeeID: employeeID, now: now)
            guard current.digest == policy.digest else { throw ReportValidationError.invalid("Chính sách vừa đổi; cần đọc lại.") }
            let urls = try FileManager.default.contentsOfDirectory(at: store.root, includingPropertiesForKeys: nil).filter { $0.pathExtension == "json" }
            var latest: [String: ReportSnapshot] = [:], warnings: [String] = []
            var versions: [String: String] = [:], conflicts: Set<String> = []
            for url in urls {
                do {
                    let snapshot = try ReportEncoding.decode(ReportSnapshot.self, from: boundedRead(url))
                    try validate(snapshot, policy: current)
                    guard snapshot.report.period.start == start else { continue }
                    let member = snapshot.report.employee.employeeID
                    if let priorHash = versions[snapshot.id], priorHash != snapshot.contentHash {
                        conflicts.insert(member)
                        throw ReportValidationError.invalid("Xung đột nội dung cùng phiên bản; bỏ tổng hợp thành viên này.")
                    }
                    versions[snapshot.id] = snapshot.contentHash
                    if let old = latest[member] {
                        guard snapshot.reportID == old.reportID else { throw ReportValidationError.invalid("Một thành viên có nhiều mã báo cáo cho cùng ngày; không tự cộng.") }
                        if snapshot.revision > old.revision { latest[member] = snapshot }
                    } else { latest[member] = snapshot }
                } catch { warnings.append(url.lastPathComponent + ": " + error.localizedDescription) }
            }
            for member in conflicts { latest.removeValue(forKey: member) }
            var gmailJobs: [GmailOutboxJob] = [], driveJobs: [DriveUploadJob] = []
            do { gmailJobs = try gmail?.all() ?? [] } catch { warnings.append("Không đọc được trạng thái Gmail cục bộ.") }
            do { driveJobs = try drive?.all() ?? [] } catch { warnings.append("Không đọc được trạng thái Drive cục bộ.") }
            let members = policy.employees.map { access in
                let snapshot = latest[access.employeeID]
                return TeamReportMember(employeeID: access.employeeID, snapshot: snapshot,
                    deliveries: snapshot.map { TeamDeliveryObservation.matching($0, gmail: gmailJobs, drive: driveJobs) } ?? [])
            }
            return TeamReportOverview(organizationID: policy.organizationID, day: start, checkedAt: now,
                members: members, warnings: warnings.sorted())
        }
    }
    private func boundedRead(_ url: URL) throws -> Data {
        let descriptor = open(url.path, O_RDONLY | O_NOFOLLOW | O_NONBLOCK)
        guard descriptor >= 0 else { throw ReportValidationError.invalid("Không mở được tệp hoặc tệp là symlink.") }
        let handle = FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
        defer { try? handle.close() }
        var metadata = stat()
        guard fstat(descriptor, &metadata) == 0, (metadata.st_mode & S_IFMT) == S_IFREG,
              metadata.st_size >= 0, metadata.st_size <= 16 * 1024 * 1024 else { throw ReportValidationError.invalid("Cần tệp thường tối đa 16 MiB.") }
        let data = try handle.read(upToCount: 16 * 1024 * 1024 + 1) ?? Data()
        guard data.count <= 16 * 1024 * 1024 else { throw ReportValidationError.invalid("Tệp vượt giới hạn dung lượng.") }
        return data
    }
}
