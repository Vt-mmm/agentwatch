import XCTest
@testable import AgentWatchCore

actor ScriptedGoogleTransport: GoogleHTTPTransport {
    enum Reply: Sendable { case http(GoogleHTTPResponse), timeout }
    private var replies: [Reply]
    private var captured: [URLRequest] = []
    init(_ replies: [Reply]) { self.replies = replies }
    func send(_ request: URLRequest) async throws -> GoogleHTTPResponse {
        captured.append(request)
        guard !replies.isEmpty else { throw GoogleServiceError.invalidResponse }
        switch replies.removeFirst() {
        case .http(let response): return response
        case .timeout: throw URLError(.timedOut)
        }
    }
    func requests() -> [URLRequest] { captured }
}

final class GoogleDeliveryTests: XCTestCase {
    private func reply(_ status: Int, _ object: [String: Any] = [:]) -> ScriptedGoogleTransport.Reply {
        .http(GoogleHTTPResponse(status: status, body: try! JSONSerialization.data(withJSONObject: object)))
    }
    private func credential(scopes: Set<String> = [GoogleScopes.driveFile, "openid", "email"]) -> GoogleCredential {
        GoogleCredential(clientID: "synthetic.apps.googleusercontent.com", subject: "synthetic-subject", email: "employee@example.test",
                         accessToken: "synthetic-access", refreshToken: "synthetic-refresh", expiresAt: Date().addingTimeInterval(3600), scopes: scopes)
    }
    private func root() throws -> URL {
        let value = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: value, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: value) }
        return value
    }
    private func snapshot() throws -> ReportSnapshot {
        let now = Date(), period = try DailyReportPeriod(day: now, timeZone: "Asia/Ho_Chi_Minh", cutoff: now)
        let draft = DailyReportDraft(employee: EmployeeProfile(organizationID: "synthetic-org", employeeID: "test-employee", displayName: "Nhân viên giả lập"), period: period,
                                    workItems: [], evidence: [], usage: [], quota: [], warnings: [], sourceFiles: [], sourceRoots: [],
                                    summary: "Report giả lập dùng kiểm tra adapter.", notes: "", narrativeProvenance: "deterministic-template-v1")
        return try ReportSnapshotStore(root: root()).save(draft, reviewedBy: "test-employee")
    }
    private var folderResponse: ScriptedGoogleTransport.Reply {
        reply(200, ["id": "folder-1", "name": "Reports", "mimeType": "application/vnd.google-apps.folder", "trashed": false, "capabilities": ["canAddChildren": true]])
    }
    private var permissionResponse: ScriptedGoogleTransport.Reply {
        reply(200, ["permissions": [["id": "owner", "type": "user", "role": "owner", "emailAddress": "employee@example.test"]]])
    }
    private var permissionHash: String { ReportEncoding.digest(Data("user | owner | employee@example.test | discoverable=false".utf8)) }
    private func prepared(_ store: DriveUploadStore) throws -> DriveUploadJob {
        let report = try snapshot()
        let job = try store.prepare(snapshot: report, destination: DriveDestination(accountKey: credential().accountKey, folderID: "folder-1", fileName: "report.pdf"),
                                    payload: DailyReportRenderer.pdf(report.report, revision: report.revision))
        return try store.approve(jobID: job.id, approver: "test-employee", folderPermissionHash: permissionHash, expectedPayloadHash: job.payloadHash)
    }
    private func fileResponse(_ job: DriveUploadJob) -> ScriptedGoogleTransport.Reply {
        reply(200, ["id": "file-1", "name": "report.pdf", "mimeType": "application/pdf", "parents": ["folder-1"], "trashed": false,
                    "appProperties": ["agentwatchReport": job.reportID, "revision": String(job.revision), "contentHash": job.reportContentHash, "payloadSHA256": job.payloadHash]])
    }

    func testPKCEStateAndCallbackBindingRejectTampering() throws {
        let attempt = try GoogleOAuthAttempt(redirectURI: "http://127.0.0.1:40000/oauth/callback", scopes: GoogleScopes.identity.union([GoogleScopes.driveFile]))
        XCTAssertEqual(attempt.verifier.count, 43)
        XCTAssertNotEqual(attempt.challenge, attempt.verifier)
        let url = try attempt.authorizationURL(configuration: GoogleOAuthConfiguration(clientID: "synthetic.apps.googleusercontent.com"))
        let query = URLComponents(url: url, resolvingAgainstBaseURL: false)!.queryItems!
        XCTAssertEqual(query.first { $0.name == "code_challenge_method" }?.value, "S256")
        XCTAssertFalse(query.contains { $0.name == "include_granted_scopes" })
        let valid = URL(string: attempt.redirectURI + "?state=\(attempt.state)&code=synthetic-code")!
        XCTAssertEqual(try attempt.authorizationCode(callback: valid), "synthetic-code")
        for value in [attempt.redirectURI + "?state=wrong&code=x", "http://127.0.0.1:40001/oauth/callback?state=\(attempt.state)&code=x", attempt.redirectURI + "?state=\(attempt.state)&code=x&code=y"] {
            XCTAssertThrowsError(try attempt.authorizationCode(callback: URL(string: value)!))
        }
        XCTAssertThrowsError(try GoogleOAuthAttempt(redirectURI: "http://0.0.0.0:40000/oauth/callback", scopes: GoogleScopes.identity))
    }
    func testOAuthExchangeVerifiesIdentityScopesAndPreservesRefreshOnRefresh() async throws {
        let attempt = try GoogleOAuthAttempt(redirectURI: "http://127.0.0.1:40000/oauth/callback", scopes: GoogleScopes.identity.union([GoogleScopes.driveFile]))
        let transport = ScriptedGoogleTransport([
            reply(200, ["access_token": "synthetic-a", "refresh_token": "synthetic-r", "expires_in": 3600, "scope": "openid https://www.googleapis.com/auth/userinfo.email \(GoogleScopes.driveFile)"]),
            reply(200, ["sub": "subject", "email": "employee@example.test", "email_verified": true]),
            reply(200, ["access_token": "synthetic-new", "expires_in": 3600])])
        let client = GoogleOAuthClient(transport: transport), config = GoogleOAuthConfiguration(clientID: "synthetic.apps.googleusercontent.com")
        let result = try await client.exchange(code: "fake-code", attempt: attempt, configuration: config)
        XCTAssertEqual(result.email, "employee@example.test")
        let refreshed = try await client.refresh(result, configuration: config)
        XCTAssertEqual(refreshed.refreshToken, "synthetic-r")
        XCTAssertEqual(refreshed.accountKey, result.accountKey)
        let requests = await transport.requests()
        XCTAssertEqual(requests[0].url?.host, "oauth2.googleapis.com")
        XCTAssertTrue(String(data: requests[0].httpBody!, encoding: .utf8)!.contains("code_verifier="))
    }
    func testOAuthMissingScopeIsRejectedBeforeIdentityCall() async throws {
        let attempt = try GoogleOAuthAttempt(redirectURI: "http://127.0.0.1:40000/oauth/callback", scopes: GoogleScopes.identity.union([GoogleScopes.driveFile]))
        let transport = ScriptedGoogleTransport([reply(200, ["access_token": "fake", "expires_in": 3600, "scope": "openid email"])])
        do {
            _ = try await GoogleOAuthClient(transport: transport).exchange(code: "fake", attempt: attempt, configuration: GoogleOAuthConfiguration(clientID: "synthetic.apps.googleusercontent.com"))
            XCTFail("Missing scope accepted")
        } catch { XCTAssertEqual(error as? GoogleServiceError, .missingScope) }
        let requests = await transport.requests(); XCTAssertEqual(requests.count, 1)
    }
    func testDriveSuccessPersistsReceiptAndNeverSendsAgainForSameJob() async throws {
        let store = DriveUploadStore(root: try root()), job = try prepared(store), bytes = try store.payload(for: job)
        let transport = ScriptedGoogleTransport([folderResponse, permissionResponse, reply(200, ["ids": ["file-1"]]), reply(404), reply(200, ["id": "file-1"]),
                                                 fileResponse(job), .http(GoogleHTTPResponse(status: 200, body: bytes))])
        let service = DriveDeliveryService(api: DriveAPI(transport: transport), store: store, policyStore: ReportTeamPolicyStore(root: store.files.root.appendingPathComponent("test-policy")))
        let done = try await service.deliver(jobID: job.id, credential: credential())
        XCTAssertEqual(done.state, .uploaded); XCTAssertEqual(done.fileID, "file-1")
        XCTAssertEqual(try store.read(job.id)?.webViewLink, "https://drive.google.com/file/d/file-1/view")
        _ = try await service.deliver(jobID: job.id, credential: credential())
        let requests = await transport.requests()
        XCTAssertEqual(requests.filter { $0.httpMethod == "POST" }.count, 1)
        XCTAssertNotNil(requests.first { $0.httpMethod == "POST" }?.httpBody?.range(of: Data("\"id\":\"file-1\"".utf8)))
    }
    func testDriveTimeoutRecoveryVerifiesSameIDWithoutSecondUpload() async throws {
        let store = DriveUploadStore(root: try root()), job = try prepared(store), bytes = try store.payload(for: job)
        let first = ScriptedGoogleTransport([folderResponse, permissionResponse, reply(200, ["ids": ["file-1"]]), reply(404), .timeout])
        do { _ = try await DriveDeliveryService(api: DriveAPI(transport: first), store: store, policyStore: ReportTeamPolicyStore(root: store.files.root.appendingPathComponent("test-policy"))).deliver(jobID: job.id, credential: credential()); XCTFail("Expected timeout") }
        catch { }
        let uncertain = try XCTUnwrap(store.read(job.id))
        XCTAssertEqual(uncertain.state, .uncertain); XCTAssertEqual(uncertain.fileID, "file-1")
        let second = ScriptedGoogleTransport([folderResponse, permissionResponse, fileResponse(job), .http(GoogleHTTPResponse(status: 200, body: bytes))])
        let done = try await DriveDeliveryService(api: DriveAPI(transport: second), store: store, policyStore: ReportTeamPolicyStore(root: store.files.root.appendingPathComponent("test-policy"))).deliver(jobID: job.id, credential: credential())
        XCTAssertEqual(done.state, .uploaded)
        let requests = await second.requests()
        XCTAssertFalse(requests.contains { $0.httpMethod == "POST" || $0.url?.path.contains("generateIds") == true })
    }
    func testChangedFolderACLBlocksUploadBeforeFileCreation() async throws {
        let store = DriveUploadStore(root: try root()), job = try prepared(store)
        let transport = ScriptedGoogleTransport([folderResponse, reply(200, ["permissions": [["id": "public", "type": "anyone", "role": "reader"]]])])
        do { _ = try await DriveDeliveryService(api: DriveAPI(transport: transport), store: store, policyStore: ReportTeamPolicyStore(root: store.files.root.appendingPathComponent("test-policy"))).deliver(jobID: job.id, credential: credential()); XCTFail("Changed ACL accepted") }
        catch { XCTAssertEqual(error as? GoogleServiceError, .permissionDenied) }
        XCTAssertNil(try store.read(job.id)?.fileID)
        let requests = await transport.requests(); XCTAssertEqual(requests.count, 2)
    }
    func testDriveRateLimitPersistsBackoffAndPreventsImmediateRetry() async throws {
        let store = DriveUploadStore(root: try root()), job = try prepared(store)
        let transport = ScriptedGoogleTransport([reply(429)])
        do { _ = try await DriveDeliveryService(api: DriveAPI(transport: transport), store: store, policyStore: ReportTeamPolicyStore(root: store.files.root.appendingPathComponent("test-policy"))).deliver(jobID: job.id, credential: credential()); XCTFail("Expected rate limit") }
        catch { XCTAssertEqual(error as? GoogleServiceError, .rateLimited) }
        let saved = try XCTUnwrap(store.read(job.id))
        let retry = try XCTUnwrap(saved.retryNotBefore)
        XCTAssertGreaterThan(retry, Date())
        XCTAssertThrowsError(try store.claim(jobID: job.id, owner: "retry", now: retry.addingTimeInterval(-1)))
    }
    func testFolderCreationTimeoutRecoversPreallocatedFolderID() async throws {
        let storage = try root()
        let first = ScriptedGoogleTransport([reply(200, ["ids": ["folder-new"]]), reply(404), .timeout])
        do { _ = try await DriveFolderCreator(api: DriveAPI(transport: first), root: storage).create(name: "Reports", credential: credential()); XCTFail("Expected timeout") }
        catch { }
        let second = ScriptedGoogleTransport([
            reply(200, ["id": "folder-new", "name": "Reports", "mimeType": "application/vnd.google-apps.folder", "trashed": false, "capabilities": ["canAddChildren": true]]), permissionResponse])
        let folder = try await DriveFolderCreator(api: DriveAPI(transport: second), root: storage).create(name: "Reports", credential: credential())
        XCTAssertEqual(folder.id, "folder-new")
        let requests = await second.requests()
        XCTAssertTrue(requests.allSatisfy { $0.httpMethod == "GET" })
        XCTAssertFalse(requests.contains { $0.url?.path.contains("generateIds") == true })
    }
    func testExistingRemoteFileWithWrongBytesIsNeverAcceptedAsReceipt() async throws {
        let store = DriveUploadStore(root: try root()), job = try prepared(store)
        let transport = ScriptedGoogleTransport([folderResponse, permissionResponse, reply(200, ["ids": ["file-1"]]), fileResponse(job), .http(GoogleHTTPResponse(status: 200, body: Data("wrong".utf8)))])
        do { _ = try await DriveDeliveryService(api: DriveAPI(transport: transport), store: store, policyStore: ReportTeamPolicyStore(root: store.files.root.appendingPathComponent("test-policy"))).deliver(jobID: job.id, credential: credential()); XCTFail("Wrong file accepted") }
        catch { XCTAssertEqual(error as? GoogleServiceError, .conflict) }
        XCTAssertNotEqual(try store.read(job.id)?.state, .uploaded)
        let requests = await transport.requests(); XCTAssertFalse(requests.contains { $0.httpMethod == "POST" })
    }
    func testApprovalRequiresExactPayloadAndEmployeeAndLeaseBlocksSecondWorker() throws {
        let store = DriveUploadStore(root: try root()), job = try prepared(store)
        XCTAssertThrowsError(try store.approve(jobID: job.id, approver: "other", folderPermissionHash: permissionHash, expectedPayloadHash: job.payloadHash))
        XCTAssertThrowsError(try store.approve(jobID: job.id, approver: "test-employee", folderPermissionHash: permissionHash, expectedPayloadHash: "changed"))
        _ = try store.claim(jobID: job.id, owner: "worker1")
        XCTAssertThrowsError(try store.claim(jobID: job.id, owner: "worker2"))
        XCTAssertThrowsError(try store.update(jobID: job.id, owner: "worker2") { $0.state = .uploaded })
    }
    func testModifiedQueuedPDFNeverUploadsAndWrongAccountIsBlocked() async throws {
        let folder = try root(), store = DriveUploadStore(root: folder), job = try prepared(store)
        try Data("changed".utf8).write(to: folder.appendingPathComponent(job.id + ".pdf"))
        XCTAssertThrowsError(try store.payload(for: job))
        var wrong = credential(); wrong.accessToken = "another-fake-token"
        let other = GoogleCredential(clientID: wrong.clientID, subject: "another", email: "other@example.test", accessToken: wrong.accessToken, refreshToken: nil, expiresAt: wrong.expiresAt, scopes: wrong.scopes)
        let transport = ScriptedGoogleTransport([])
        do { _ = try await DriveDeliveryService(api: DriveAPI(transport: transport), store: store, policyStore: ReportTeamPolicyStore(root: store.files.root.appendingPathComponent("test-policy"))).deliver(jobID: job.id, credential: other); XCTFail("Wrong account accepted") }
        catch { XCTAssertEqual(error as? GoogleServiceError, .wrongAccount) }
        let requests = await transport.requests(); XCTAssertTrue(requests.isEmpty)
    }
}
