import Foundation

/// Derived only after the existing app-open key verifier succeeds. Neither the
/// enrollment key nor its authentication digest is included in report metadata.
public struct ReportEnrollmentIdentity: Sendable, Equatable {
    public let employeeID: String
    public let name: String
    public init(enrollmentHash: String, label: String) throws {
        guard enrollmentHash.range(of: "^[a-fA-F0-9]{64}$", options: .regularExpression) != nil,
              !label.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { throw GoogleServiceError.invalidConfiguration }
        employeeID = "member-" + ReportEncoding.digest(Data(("agentwatch-report-member-v1|" + enrollmentHash.lowercased()).utf8))
        name = label.trimmingCharacters(in: .whitespacesAndNewlines)
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
              binding.folderID == destination.folderID else { throw ReportValidationError.invalid("Đích upload không khớp thư mục đã gắn với key.") }
    }
    public func bind(organizationID: String, identity: ReportEnrollmentIdentity, accountKey: String, folder: DriveFolderAccess, now: Date = Date()) throws -> ReportFolderBinding {
        guard !organizationID.isEmpty, !accountKey.isEmpty, DriveAPI.validID(folder.id) else { throw GoogleServiceError.invalidConfiguration }
        let proposed = ReportFolderBinding(organizationID: organizationID, employeeID: identity.employeeID, accountKey: accountKey,
                                          folderID: folder.id, folderName: folder.name, boundAt: now)
        return try files.transaction {
            let current = try allUnlocked()
            if let existing = current.first(where: { $0.id == proposed.id }) {
                guard existing.folderID == proposed.folderID else { throw ReportValidationError.invalid("Key này đã gắn với thư mục khác. Dùng thư mục đã gắn; việc chuyển đích cần quản trị viên xử lý.") }
                return existing
            }
            guard !current.contains(where: { $0.organizationID == organizationID && $0.folderID == folder.id && $0.employeeID != identity.employeeID }) else {
                throw ReportValidationError.invalid("Thư mục này đã gắn với key của người khác trên máy.")
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
