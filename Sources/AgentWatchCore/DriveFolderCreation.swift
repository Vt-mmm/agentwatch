import Foundation

public struct DriveFolderCreation: Codable, Sendable {
    public let accountKey: String
    public let name: String
    public var fileID: String?
    public var confirmed: Bool
    public var leaseOwner: String?
    public var leaseUntil: Date?
    public var parentID: String? = nil
    public var identityKey: String? = nil
}
public struct DriveFolderCreator: Sendable {
    public let api: DriveAPI
    public let files: ReportFileStore
    public init(api: DriveAPI = DriveAPI(), root: URL = ReportSnapshotStore.local.files.root.appendingPathComponent("drive-folders")) {
        self.api = api; self.files = ReportFileStore(root: root)
    }
    /// Called by the explicitly labelled create-folder action. Persist the
    /// generated ID before POST, and recover that same folder after a timeout.
    public func create(name: String, credential: GoogleCredential, parentID: String? = nil, identityKey: String? = nil) async throws -> DriveFolderAccess {
        guard !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, name.count <= 200,
              !name.contains("\n"), !name.contains("/") else { throw GoogleServiceError.invalidConfiguration }
        guard parentID.map(DriveAPI.validID) ?? true, identityKey.map({ !$0.isEmpty }) ?? true else { throw GoogleServiceError.invalidConfiguration }
        let namespace = parentID == nil && identityKey == nil ? name : "parent=\(parentID ?? "root")|identity=\(identityKey ?? name)"
        let key = ReportEncoding.digest(Data((credential.accountKey + "|" + namespace).utf8))
        let url = files.root.appendingPathComponent(key + ".json"), owner = UUID().uuidString
        var saved: DriveFolderCreation = try files.transaction {
            var value = FileManager.default.fileExists(atPath: url.path)
                ? try ReportEncoding.decode(DriveFolderCreation.self, from: Data(contentsOf: url))
                : DriveFolderCreation(accountKey: credential.accountKey, name: name, fileID: nil, confirmed: false, leaseOwner: nil, leaseUntil: nil)
            if value.fileID == nil { value.parentID = parentID; value.identityKey = identityKey }
            guard value.accountKey == credential.accountKey, value.parentID == parentID, value.identityKey == identityKey,
                  identityKey != nil || value.name == name else { throw GoogleServiceError.conflict }
            if let until = value.leaseUntil, until > Date() { throw GoogleServiceError.storage("Đang tạo thư mục Drive.") }
            value.leaseOwner = owner; value.leaseUntil = Date().addingTimeInterval(180)
            try files.write(ReportEncoding.encode(value), to: url); return value
        }
        func persist(_ value: DriveFolderCreation) throws {
            try files.transaction {
                let current = try ReportEncoding.decode(DriveFolderCreation.self, from: Data(contentsOf: url))
                guard current.leaseOwner == owner else { throw GoogleServiceError.conflict }
                try files.write(ReportEncoding.encode(value), to: url)
            }
        }
        do {
            if let parentID { _ = try await api.folder(parentID, credential: credential) }
            if saved.fileID == nil { saved.fileID = try await api.generateID(credential: credential); try persist(saved) }
            let id = saved.fileID!
            var found: DriveFolderAccess?
            do { found = try await api.folder(id, credential: credential, expectedParentID: parentID) }
            catch GoogleServiceError.notFound { }
            if found == nil {
                var object: [String: Any] = ["id": id, "name": saved.name, "mimeType": "application/vnd.google-apps.folder",
                                             "appProperties": ["agentwatchFolder": key]]
                if let parentID { object["parents"] = [parentID] }
                let response = try await api.transport.send(GoogleWire.request(url: URL(string: "https://www.googleapis.com/drive/v3/files?fields=id&supportsAllDrives=true")!, method: "POST", token: credential.accessToken,
                                                                                body: JSONSerialization.data(withJSONObject: object), contentType: "application/json"))
                guard (200...299).contains(response.status) || response.status == 409 else { throw GoogleServiceError.from(status: response.status) }
                found = try await api.folder(id, credential: credential, expectedParentID: parentID)
            }
            guard let found, found.id == id, identityKey != nil || found.name == name else { throw GoogleServiceError.conflict }
            saved.confirmed = true; saved.leaseOwner = nil; saved.leaseUntil = nil; try persist(saved)
            return found
        } catch {
            saved.leaseOwner = nil; saved.leaseUntil = nil; try? persist(saved)
            throw error
        }
    }
}
