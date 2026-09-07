import Foundation

public struct ReportEmployeeAccess: Codable, Sendable, Equatable {
    public var employeeID: String
    public var googleAccountKeys: [String]
    public var recipients: [String]
    public var driveFolderIDs: [String]
}
public struct ReportTeamPolicy: Codable, Sendable, Equatable {
    public var schemaVersion: Int = 1
    public var organizationID: String
    public var revision: Int
    public var owner: String
    public var timeZone: String
    public var employees: [ReportEmployeeAccess]
    public var allowGmail: Bool
    public var allowDrive: Bool
    public var allowScheduledDelivery: Bool
    public var allowNarrativeExport: Bool
    public var retentionDays: Int
    public var effectiveFrom: Date
    public var expiresAt: Date
    public var digest: String { ReportEncoding.digest((try? ReportEncoding.encode(self)) ?? Data()) }
    public func validate() throws {
        guard schemaVersion == 1, !organizationID.isEmpty, revision > 0, !owner.isEmpty,
              TimeZone(identifier: timeZone) != nil, (7...3650).contains(retentionDays),
              expiresAt > effectiveFrom, !employees.isEmpty,
              Set(employees.map(\.employeeID)).count == employees.count else { throw GoogleServiceError.invalidConfiguration }
        for employee in employees {
            guard !employee.employeeID.isEmpty, !employee.googleAccountKeys.isEmpty,
                  employee.googleAccountKeys.allSatisfy({ $0.range(of: "^[a-f0-9]{64}$", options: .regularExpression) != nil }),
                  employee.recipients.allSatisfy(ReportMailDestination.validAddress),
                  employee.driveFolderIDs.allSatisfy(DriveAPI.validID) else { throw GoogleServiceError.invalidConfiguration }
        }
    }
    public func access(organizationID: String, employeeID: String, accountKey: String, now: Date = Date()) throws -> ReportEmployeeAccess {
        try validate()
        guard self.organizationID == organizationID, effectiveFrom <= now, now < expiresAt,
              let employee = employees.first(where: { $0.employeeID == employeeID }), employee.googleAccountKeys.contains(accountKey) else {
            throw ReportValidationError.invalid("Tài khoản/nhân viên ngoài chính sách công ty hoặc chính sách đã hết hạn.")
        }
        return employee
    }
}

public struct ReportTeamPolicyStore: Sendable {
    public let files: ReportFileStore
    public let managedURL: URL?
    public init(root: URL, managedURL: URL? = nil) { files = ReportFileStore(root: root); self.managedURL = managedURL }
    public static var local: Self {
        Self(root: ReportSnapshotStore.local.files.root.appendingPathComponent("team"),
             managedURL: URL(fileURLWithPath: "/Library/Application Support/AgentWatch/managed-report-policy.json"))
    }
    public func load() throws -> ReportTeamPolicy? {
        if let managedURL, FileManager.default.fileExists(atPath: managedURL.path) {
            // A broken managed policy must never fall back to permissive mode.
            let metadata = try FileManager.default.attributesOfItem(atPath: managedURL.path)
            guard (metadata[.ownerAccountID] as? NSNumber)?.intValue == 0,
                  let mode = metadata[.posixPermissions] as? NSNumber, mode.intValue & 0o022 == 0,
                  metadata[.type] as? FileAttributeType == .typeRegular else { throw GoogleServiceError.permissionDenied }
            return try decode(Data(contentsOf: managedURL))
        }
        return try files.transaction {
            let url = files.root.appendingPathComponent("policy.json")
            guard FileManager.default.fileExists(atPath: url.path) else { return nil }
            return try decode(Data(contentsOf: url))
        }
    }
    public func decode(_ data: Data) throws -> ReportTeamPolicy {
        try ReportSchema.validatePolicy(data)
        let policy = try ReportEncoding.decode(ReportTeamPolicy.self, from: data); try policy.validate(); return policy
    }
    public func install(_ data: Data, expectedHash: String, confirmedBy: String) throws {
        let policy = try decode(data)
        guard policy.digest == expectedHash, confirmedBy == policy.owner else { throw GoogleServiceError.permissionDenied }
        if let managedURL, FileManager.default.fileExists(atPath: managedURL.path) { throw GoogleServiceError.permissionDenied }
        try files.transaction {
            let url = files.root.appendingPathComponent("policy.json")
            if FileManager.default.fileExists(atPath: url.path) {
                let prior = try decode(Data(contentsOf: url))
                guard policy.organizationID == prior.organizationID, policy.revision > prior.revision else { throw GoogleServiceError.conflict }
            }
            try files.write(ReportEncoding.encode(policy), to: url)
        }
    }
    public func checkGmail(organizationID: String, employeeID: String, destination: ReportMailDestination, scheduled: Bool = false, timeZone: String? = nil) throws {
        guard let policy = try load() else {
            if scheduled { throw GoogleServiceError.permissionDenied }; return
        }
        let access = try policy.access(organizationID: organizationID, employeeID: employeeID, accountKey: destination.accountKey)
        if let timeZone, timeZone != policy.timeZone { throw ReportValidationError.invalid("Múi giờ report không khớp chính sách công ty.") }
        let recipients = Set(access.recipients.map { $0.lowercased() })
        guard policy.allowGmail, (!scheduled || policy.allowScheduledDelivery), destination.recipients.allSatisfy({ recipients.contains($0.lowercased()) }) else {
            throw ReportValidationError.invalid("Chính sách công ty chưa cho phép kênh Gmail, lịch gửi hoặc một người nhận trong To/Cc/Bcc.")
        }
    }
    public func checkDrive(organizationID: String, employeeID: String, destination: DriveDestination, scheduled: Bool = false, timeZone: String? = nil) throws {
        guard let policy = try load() else {
            if scheduled { throw GoogleServiceError.permissionDenied }; return
        }
        let access = try policy.access(organizationID: organizationID, employeeID: employeeID, accountKey: destination.accountKey)
        if let timeZone, timeZone != policy.timeZone { throw ReportValidationError.invalid("Múi giờ report không khớp chính sách công ty.") }
        guard policy.allowDrive, (!scheduled || policy.allowScheduledDelivery), access.driveFolderIDs.contains(destination.folderID) else {
            throw ReportValidationError.invalid("Chính sách công ty chưa cho phép kênh Drive, lịch upload hoặc thư mục này.")
        }
    }
}
