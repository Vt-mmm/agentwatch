import Foundation

public struct DriveFolderAccess: Sendable, Equatable {
    public let id: String
    public let name: String
    public let permissions: [String]
    public let permissionHash: String
    public let sharedDrive: Bool
}

public struct DriveAPI: Sendable {
    public let transport: any GoogleHTTPTransport
    public init(transport: any GoogleHTTPTransport = GoogleURLSessionTransport()) { self.transport = transport }
    public static func validID(_ value: String) -> Bool {
        value.count <= 256 && value.range(of: "^[A-Za-z0-9_-]+$", options: .regularExpression) != nil
    }
    private func url(_ path: String, query: [String: String] = [:], upload: Bool = false) -> URL {
        var parts = URLComponents(string: "https://www.googleapis.com/\(upload ? "upload/" : "")drive/v3/" + path)!
        parts.queryItems = query.keys.sorted().map { URLQueryItem(name: $0, value: query[$0]) }
        return parts.url!
    }
    private func authorized(_ credential: GoogleCredential) throws {
        guard credential.scopes.contains(GoogleScopes.driveFile) else { throw GoogleServiceError.missingScope }
        guard credential.expiresAt > Date().addingTimeInterval(30) else { throw GoogleServiceError.authenticationRequired }
    }
    public func folder(_ id: String, credential: GoogleCredential, expectedParentID: String? = nil) async throws -> DriveFolderAccess {
        try authorized(credential); guard Self.validID(id) else { throw GoogleServiceError.invalidConfiguration }
        let fields = "id,name,mimeType,trashed,driveId,capabilities(canAddChildren)" + (expectedParentID == nil ? "" : ",parents")
        let response = try await transport.send(GoogleWire.request(url: url("files/" + id, query: ["supportsAllDrives": "true", "fields": fields]), token: credential.accessToken))
        guard response.status == 200 else { throw GoogleServiceError.from(response: response) }
        let data = try GoogleWire.json(response.body)
        if let expectedParentID, (data["parents"] as? [String])?.contains(expectedParentID) != true { throw GoogleServiceError.conflict }
        guard data["id"] as? String == id, data["mimeType"] as? String == "application/vnd.google-apps.folder",
              data["trashed"] as? Bool != true, (data["capabilities"] as? [String: Any])?["canAddChildren"] as? Bool == true else { throw GoogleServiceError.permissionDenied }
        let acl = try await permissions(fileID: id, credential: credential)
        guard !acl.isEmpty else { throw GoogleServiceError.invalidResponse }
        return DriveFolderAccess(id: id, name: data["name"] as? String ?? id, permissions: acl,
                                 permissionHash: ReportEncoding.digest(Data(acl.joined(separator: "\n").utf8)), sharedDrive: data["driveId"] != nil)
    }
    public func permissions(fileID: String, credential: GoogleCredential) async throws -> [String] {
        try authorized(credential); guard Self.validID(fileID) else { throw GoogleServiceError.invalidConfiguration }
        var out: [String] = [], pageToken: String?
        repeat {
            var query = ["supportsAllDrives": "true", "pageSize": "100", "fields": "nextPageToken,permissions(id,type,role,emailAddress,domain,allowFileDiscovery)"]
            if let pageToken { query["pageToken"] = pageToken }
            let response = try await transport.send(GoogleWire.request(url: url("files/\(fileID)/permissions", query: query), token: credential.accessToken))
            guard response.status == 200 else { throw GoogleServiceError.from(response: response) }
            let body = try GoogleWire.json(response.body)
            guard let rows = body["permissions"] as? [[String: Any]] else { throw GoogleServiceError.invalidResponse }
            for row in rows {
                guard let type = row["type"] as? String, let role = row["role"] as? String else { throw GoogleServiceError.invalidResponse }
                let identity = row["emailAddress"] as? String ?? row["domain"] as? String ?? row["id"] as? String ?? "unknown"
                out.append("\(type) | \(role) | \(identity) | discoverable=\(row["allowFileDiscovery"] as? Bool ?? false)")
            }
            pageToken = body["nextPageToken"] as? String
            guard out.count <= 10_000 else { throw GoogleServiceError.invalidResponse }
        } while pageToken != nil
        return out.sorted()
    }
    public func generateID(credential: GoogleCredential) async throws -> String {
        try authorized(credential)
        let response = try await transport.send(GoogleWire.request(url: url("files/generateIds", query: ["count": "1", "space": "drive", "type": "files"]), token: credential.accessToken))
        guard response.status == 200 else { throw GoogleServiceError.from(response: response) }
        guard let id = (try GoogleWire.json(response.body)["ids"] as? [String])?.first, Self.validID(id) else { throw GoogleServiceError.invalidResponse }
        return id
    }
    public func upload(job: DriveUploadJob, bytes: Data, credential: GoogleCredential) async throws {
        try authorized(credential)
        guard let id = job.fileID, Self.validID(id), bytes.count <= 5_000_000 else { throw GoogleServiceError.unsupportedSize }
        let metadata: [String: Any] = ["id": id, "name": job.destination.fileName, "parents": [job.destination.folderID], "mimeType": "application/pdf",
            "appProperties": ["agentwatchReport": job.reportID, "revision": String(job.revision), "contentHash": job.reportContentHash, "payloadSHA256": job.payloadHash]]
        let boundary = "agentwatch-" + UUID().uuidString
        var body = Data("--\(boundary)\r\nContent-Type: application/json; charset=UTF-8\r\n\r\n".utf8)
        body.append(try JSONSerialization.data(withJSONObject: metadata, options: [.sortedKeys]))
        body.append(Data("\r\n--\(boundary)\r\nContent-Type: application/pdf\r\n\r\n".utf8)); body.append(bytes)
        body.append(Data("\r\n--\(boundary)--\r\n".utf8))
        let response = try await transport.send(GoogleWire.request(url: url("files", query: ["uploadType": "multipart", "supportsAllDrives": "true", "fields": "id"], upload: true), method: "POST", token: credential.accessToken, body: body, contentType: "multipart/related; boundary=\(boundary)"))
        guard (200...299).contains(response.status) else { throw GoogleServiceError.from(response: response) }
        guard try GoogleWire.json(response.body)["id"] as? String == id else { throw GoogleServiceError.invalidResponse }
    }
    public func verify(job: DriveUploadJob, credential: GoogleCredential) async throws -> String? {
        try authorized(credential)
        guard let id = job.fileID, Self.validID(id) else { return nil }
        let response = try await transport.send(GoogleWire.request(url: url("files/" + id, query: ["supportsAllDrives": "true", "fields": "id,name,mimeType,parents,trashed,appProperties,webViewLink,size"]), token: credential.accessToken))
        if response.status == 404 { return nil }
        guard response.status == 200 else { throw GoogleServiceError.from(response: response) }
        let file = try GoogleWire.json(response.body), properties = file["appProperties"] as? [String: String] ?? [:]
        guard file["id"] as? String == id, file["name"] as? String == job.destination.fileName,
              file["mimeType"] as? String == "application/pdf", file["trashed"] as? Bool != true,
              (file["parents"] as? [String])?.contains(job.destination.folderID) == true,
              properties["agentwatchReport"] == job.reportID, properties["revision"] == String(job.revision),
              properties["contentHash"] == job.reportContentHash, properties["payloadSHA256"] == job.payloadHash else { throw GoogleServiceError.conflict }
        let media = try await transport.send(GoogleWire.request(url: url("files/" + id, query: ["alt": "media", "supportsAllDrives": "true"]), token: credential.accessToken))
        guard media.status == 200, media.body.count == job.payloadBytes, ReportEncoding.digest(media.body) == job.payloadHash else { throw GoogleServiceError.conflict }
        return "https://drive.google.com/file/d/\(id)/view"
    }
}

public struct DriveDeliveryService: Sendable {
    public let api: DriveAPI
    public let store: DriveUploadStore
    public let policyStore: ReportTeamPolicyStore
    public let bindings: ReportFolderBindingStore
    public init(api: DriveAPI = DriveAPI(), store: DriveUploadStore = .local, policyStore: ReportTeamPolicyStore = .local, bindings: ReportFolderBindingStore = .local) {
        self.api = api; self.store = store; self.policyStore = policyStore; self.bindings = bindings
    }
    public func deliver(jobID: String, credential: GoogleCredential, expectedPolicyHash: String? = nil) async throws -> DriveUploadJob {
        let owner = UUID().uuidString
        if let expectedPolicyHash, try policyStore.load()?.digest != expectedPolicyHash { throw GoogleServiceError.permissionDenied }
        guard let prepared = try store.read(jobID) else { throw GoogleServiceError.notFound }
        try bindings.requireMatch(organizationID: prepared.organizationID ?? "", employeeID: prepared.employeeID, destination: prepared.destination)
        try policyStore.checkDrive(organizationID: prepared.organizationID ?? "", employeeID: prepared.employeeID, destination: prepared.destination, timeZone: prepared.reportTimeZone ?? "")
        var job = try store.claim(jobID: jobID, owner: owner)
        guard credential.accountKey == job.destination.accountKey else {
            if job.state != .uploaded { _ = try? store.update(jobID: jobID, owner: owner) { $0.state = .failed; $0.leaseOwner = nil; $0.leaseUntil = nil; $0.lastError = "Wrong Google account." } }
            throw GoogleServiceError.wrongAccount
        }
        if job.state == .uploaded { return job }
        do {
            let folder = try await api.folder(job.destination.folderID, credential: credential)
            guard folder.permissionHash == job.approval?.folderPermissionHash else { throw GoogleServiceError.permissionDenied }
            let bytes = try store.payload(for: job)
            if job.fileID == nil {
                let id = try await api.generateID(credential: credential)
                job = try store.update(jobID: jobID, owner: owner) { $0.fileID = id }
            }
            var link = try await api.verify(job: job, credential: credential)
            if link == nil {
                do { try await api.upload(job: job, bytes: bytes, credential: credential) }
                catch GoogleServiceError.conflict { /* Same fixed ID may already exist: verify below. */ }
                link = try await api.verify(job: job, credential: credential)
            }
            guard let link else { throw GoogleServiceError.uncertain }
            return try store.update(jobID: jobID, owner: owner) {
                $0.state = .uploaded; $0.webViewLink = link; $0.leaseOwner = nil; $0.leaseUntil = nil; $0.lastError = nil
            }
        } catch {
            let known = error as? GoogleServiceError
            _ = try? store.update(jobID: jobID, owner: owner) {
                $0.state = known == .authenticationRequired || known == .permissionDenied || known == .rateLimited ? .failed : .uncertain
                $0.lastError = known?.localizedDescription ?? GoogleServiceError.uncertain.localizedDescription
                if known == .rateLimited {
                    let delay = min(300, pow(2, Double(min($0.attemptCount, 8))) * 5) * Double.random(in: 0.8...1.2)
                    $0.retryNotBefore = Date().addingTimeInterval(delay)
                }
                $0.leaseOwner = nil; $0.leaseUntil = nil
            }
            throw error
        }
    }
}
