import Foundation

public struct GmailAPI: Sendable {
    public let transport: any GoogleHTTPTransport
    public init(transport: any GoogleHTTPTransport = GoogleURLSessionTransport()) { self.transport = transport }
    public func send(mime: Data, credential: GoogleCredential) async throws -> (messageID: String, threadID: String?) {
        let body = try JSONSerialization.data(withJSONObject: ["raw": ReportMailRenderer.base64URL(mime)])
        let response = try await transport.send(GoogleWire.request(url: URL(string: "https://gmail.googleapis.com/gmail/v1/users/me/messages/send")!,
            method: "POST", token: credential.accessToken, body: body, contentType: "application/json"))
        guard response.status == 200 else {
            if Self.failure(response) == .rateLimited { throw GoogleRateLimitFailure(response: response) }
            throw Self.failure(response)
        }
        let object = try GoogleWire.json(response.body)
        guard let id = object["id"] as? String, GmailOutboxStore.validReceiptID(id) else { throw GoogleServiceError.uncertain }
        let threadID = object["threadId"] as? String
        guard threadID == nil || GmailOutboxStore.validReceiptID(threadID) else { throw GoogleServiceError.uncertain }
        return (id, threadID)
    }
    static func failure(_ response: GoogleHTTPResponse) -> GoogleServiceError {
        if response.status == 403, let object = try? GoogleWire.json(response.body), let error = object["error"] as? [String: Any],
           let rows = error["errors"] as? [[String: Any]], rows.contains(where: {
               ["rateLimitExceeded", "userRateLimitExceeded", "dailyLimitExceeded"].contains($0["reason"] as? String ?? "")
           }) { return .rateLimited }
        // Unexpected redirects, 2xx shapes and all 5xx are ambiguous for a send.
        if [400, 401, 403, 404, 429].contains(response.status) { return .from(status: response.status) }
        return .uncertain
    }
}

public struct GmailDeliveryService: Sendable {
    public let api: GmailAPI
    public let store: GmailOutboxStore
    public let policyStore: ReportTeamPolicyStore
    public init(api: GmailAPI = GmailAPI(), store: GmailOutboxStore = .local, policyStore: ReportTeamPolicyStore = .local) { self.api = api; self.store = store; self.policyStore = policyStore }
    public func deliver(jobID: String, credential: GoogleCredential, expectedPolicyHash: String? = nil) async throws -> GmailOutboxJob {
        guard let prepared = try store.read(jobID) else { throw GoogleServiceError.notFound }
        if let expectedPolicyHash, try policyStore.load()?.digest != expectedPolicyHash { throw GoogleServiceError.permissionDenied }
        try policyStore.checkGmail(organizationID: prepared.organizationID ?? "", employeeID: prepared.employeeID, destination: prepared.destination, timeZone: prepared.reportTimeZone ?? "")
        guard prepared.destination.accountKey == credential.accountKey,
              prepared.destination.from == credential.email else { throw GoogleServiceError.wrongAccount }
        guard credential.scopes.contains(GoogleScopes.gmailSend) else { throw GoogleServiceError.missingScope }
        guard credential.expiresAt > Date().addingTimeInterval(30) else { throw GoogleServiceError.authenticationRequired }
        let owner = UUID().uuidString
        let job = try store.claim(jobID, owner: owner)
        if [.accepted, .manuallyConfirmed].contains(job.state) { return job }
        do {
            let receipt = try await api.send(mime: store.payload(for: job), credential: credential)
            return try store.finish(jobID, owner: owner, state: .accepted, messageID: receipt.messageID, threadID: receipt.threadID)
        } catch {
            let limit = error as? GoogleRateLimitFailure
            let known = limit == nil ? error as? GoogleServiceError : GoogleServiceError.rateLimited
            let rejected = known == .authenticationRequired || known == .permissionDenied || known == .rateLimited || known == .rejected(400) || known == .notFound
            let delay = min(3600, pow(2, Double(min(job.attempts.count, 10))) * 30) * Double.random(in: 0.8...1.2)
            _ = try? store.finish(jobID, owner: owner, state: rejected ? .failed : .uncertain,
                                  error: (known ?? .uncertain).localizedDescription,
                                  retryAt: known == .rateLimited ? max(Date().addingTimeInterval(delay), limit?.retryAt ?? .distantPast) : nil)
            throw known ?? error
        }
    }
}
