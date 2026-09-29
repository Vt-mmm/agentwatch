import Foundation

/// Stable report identity. Legacy enrollment-derived IDs remain readable;
/// new installations create a local ID without an app-open or unlock key.
public struct ReportEnrollmentIdentity: Sendable, Equatable {
    public let employeeID: String
    public let name: String
    public init(enrollmentHash: String, label: String) throws {
        guard enrollmentHash.range(of: "^[a-fA-F0-9]{64}$", options: .regularExpression) != nil,
              !label.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { throw GoogleServiceError.invalidConfiguration }
        employeeID = "member-" + ReportEncoding.digest(Data(("agentwatch-report-member-v1|" + enrollmentHash.lowercased()).utf8))
        name = label.trimmingCharacters(in: .whitespacesAndNewlines)
    }
    public init(employeeID: String, name: String) throws {
        guard employeeID.range(of: "^[A-Za-z0-9][A-Za-z0-9._-]{0,159}$", options: .regularExpression) != nil,
              !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { throw GoogleServiceError.invalidConfiguration }
        self.employeeID = employeeID
        self.name = name.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Preserve existing report history and Drive bindings; never generate an auth credential.
    public static func local(defaults: UserDefaults, deviceName: String) throws -> Self {
        let savedID = defaults.string(forKey: "dailyReport.employeeID")?.trimmingCharacters(in: .whitespacesAndNewlines)
        let savedName = defaults.string(forKey: "dailyReport.displayName")?.trimmingCharacters(in: .whitespacesAndNewlines)
        let id = savedID.flatMap { $0.isEmpty ? nil : $0 } ?? "member-" + ReportEncoding.digest(Data(UUID().uuidString.utf8))
        let name = savedName.flatMap { $0.isEmpty ? nil : $0 } ?? deviceName
        let identity = try Self(employeeID: id, name: name)
        defaults.set(identity.employeeID, forKey: "dailyReport.employeeID")
        defaults.set(identity.name, forKey: "dailyReport.displayName")
        return identity
    }
    public var folderName: String {
        name.replacingOccurrences(of: "/", with: "-").replacingOccurrences(of: "\\", with: "-")
            .components(separatedBy: .controlCharacters).joined(separator: " ")
    }
}

public struct ReportFolderBinding: Codable, Sendable, Equatable {
    public let organizationID: String
    public let employeeID: String
    public let accountKey: String
    public let folderID: String
    public let folderName: String
    public let boundAt: Date
    public var id: String { ReportEncoding.digest(Data("\(organizationID)|\(employeeID)|\(accountKey)".utf8)) }
}

public struct ReportFolderBindingStore: Sendable {
    public let files: ReportFileStore
    public init(root: URL) { files = ReportFileStore(root: root) }
    public static var local: Self { Self(root: ReportSnapshotStore.local.files.root.appendingPathComponent("employee-drive-folders")) }
    public func read(organizationID: String, employeeID: String, accountKey: String) throws -> ReportFolderBinding? {
        try files.transaction { try allUnlocked().first { $0.organizationID == organizationID && $0.employeeID == employeeID && $0.accountKey == accountKey } }
    }
    public func requireMatch(organizationID: String, employeeID: String, destination: DriveDestination) throws {
        guard employeeID.hasPrefix("member-") else { return } // Existing manual profiles retain their workflow.
        guard let binding = try read(organizationID: organizationID, employeeID: employeeID, accountKey: destination.accountKey),
              binding.folderID == destination.folderID else { throw ReportValidationError.invalid("Đích upload không khớp thư mục của hồ sơ báo cáo.") }
    }
    public func bind(organizationID: String, identity: ReportEnrollmentIdentity, accountKey: String, folder: DriveFolderAccess, now: Date = Date()) throws -> ReportFolderBinding {
        guard !organizationID.isEmpty, !accountKey.isEmpty, DriveAPI.validID(folder.id) else { throw GoogleServiceError.invalidConfiguration }
        let proposed = ReportFolderBinding(organizationID: organizationID, employeeID: identity.employeeID, accountKey: accountKey,
                                          folderID: folder.id, folderName: folder.name, boundAt: now)
        return try files.transaction {
            let current = try allUnlocked()
            if let existing = current.first(where: { $0.id == proposed.id }) {
                guard existing.folderID == proposed.folderID else { throw ReportValidationError.invalid("Hồ sơ này đã gắn với thư mục khác. Dùng thư mục đã gắn; việc chuyển đích cần quản trị viên xử lý.") }
                return existing
            }
            guard !current.contains(where: { $0.organizationID == organizationID && $0.folderID == folder.id && $0.employeeID != identity.employeeID }) else {
                throw ReportValidationError.invalid("Thư mục này đã gắn với hồ sơ khác trên máy.")
            }
            try files.write(ReportEncoding.encode(proposed), to: files.root.appendingPathComponent(proposed.id + ".json"))
            return proposed
        }
    }
    private func allUnlocked() throws -> [ReportFolderBinding] {
        try FileManager.default.contentsOfDirectory(at: files.root, includingPropertiesForKeys: nil).filter { $0.pathExtension == "json" }.map { url in
            let value = try ReportEncoding.decode(ReportFolderBinding.self, from: Data(contentsOf: url))
            guard url.lastPathComponent == value.id + ".json", DriveAPI.validID(value.folderID) else { throw GoogleServiceError.invalidResponse }
            return value
        }
    }
}
