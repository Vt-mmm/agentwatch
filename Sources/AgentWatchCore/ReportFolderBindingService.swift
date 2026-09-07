import Foundation

/// Binds an existing employee folder using only access to that folder.
/// Parent traversal and folder creation are not part of employee setup.
public struct ReportFolderBindingService: Sendable {
    public let api: DriveAPI
    public let bindings: ReportFolderBindingStore
    public let policy: ReportTeamPolicyStore
    public init(api: DriveAPI = DriveAPI(), bindings: ReportFolderBindingStore = .local,
                policy: ReportTeamPolicyStore = .local) {
        self.api = api; self.bindings = bindings; self.policy = policy
    }
    public func bind(folderID: String, organizationID: String, identity: ReportEnrollmentIdentity,
                     credential: GoogleCredential, timeZone: String) async throws -> ReportFolderBinding {
        let id = try GoogleDesktopClientFile.folderID(folderID)
        try policy.checkDrive(organizationID: organizationID, employeeID: identity.employeeID,
            destination: DriveDestination(accountKey: credential.accountKey, folderID: id, fileName: "report.pdf"), timeZone: timeZone)
        let folder = try await api.folder(id, credential: credential)
        return try bindings.bind(organizationID: organizationID, identity: identity,
                                 accountKey: credential.accountKey, folder: folder)
    }
}
