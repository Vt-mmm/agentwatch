import XCTest
@testable import AgentWatchCore

final class GmailDeliveryTests: XCTestCase {
    private func root() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: url) }; return url
    }
    private func credential(subject: String = "synthetic") -> GoogleCredential {
        GoogleCredential(clientID: "test.apps.googleusercontent.com", subject: subject, email: "employee@example.test", accessToken: "fake-token",
                         refreshToken: nil, expiresAt: Date().addingTimeInterval(3600), scopes: [GoogleScopes.gmailSend])
    }
    private func snapshot() throws -> ReportSnapshot {
        let now = Date()
        let report = DailyReportDraft(employee: EmployeeProfile(organizationID: "test", employeeID: "employee", displayName: "Nhân viên giả lập"),
            period: try DailyReportPeriod(day: now, timeZone: "Asia/Ho_Chi_Minh", cutoff: now), workItems: [], evidence: [], usage: [], quota: [],
            warnings: [], sourceFiles: [], sourceRoots: [], summary: "Báo cáo tiếng Việt & <nội dung>", notes: "", narrativeProvenance: "deterministic-template-v1")
        return try ReportSnapshotStore(root: root()).save(report, reviewedBy: "employee")
    }
    private func destination(to: String = "boss@example.test") throws -> ReportMailDestination {
        try ReportMailDestination(accountKey: credential().accountKey, from: credential().email, to: [to],
                                  cc: ["cc@example.test"], bcc: ["bcc@example.test"], subject: String(repeating: "Báo cáo ngày 🧪 ", count: 5))
    }
    private func prepared(_ store: GmailOutboxStore) throws -> GmailOutboxJob {
        let job = try store.prepare(snapshot: snapshot(), destination: destination())
        return try store.approve(job.id, employeeID: "employee", expectedPayloadHash: job.payloadHash)
    }
    private func response(_ status: Int, _ body: [String: Any] = [:]) -> ScriptedGoogleTransport.Reply {
        .http(GoogleHTTPResponse(status: status, body: try! JSONSerialization.data(withJSONObject: body)))
    }
    func testMIMEHasExactPDFUnicodeSubjectAndSeparateRecipients() throws {
        let report = try snapshot(), dest = try destination(), payload = try ReportMailRenderer.render(snapshot: report, destination: dest)
        let mime = try XCTUnwrap(String(data: payload.mime, encoding: .utf8))
        XCTAssertTrue(mime.contains("To: boss@example.test\r\nCc: cc@example.test\r\nBcc: bcc@example.test\r\n"))
        XCTAssertTrue(mime.contains("multipart/alternative")); XCTAssertTrue(mime.contains("Content-Disposition: attachment;"))
        XCTAssertTrue(mime.contains(payload.messageID))
        let words = ReportMailRenderer.encodedSubject(dest.subject).components(separatedBy: "\r\n ")
        let decoded = try words.map { word -> String in
            XCTAssertLessThanOrEqual(word.count, 75)
            let data = try XCTUnwrap(Data(base64Encoded: String(word.dropFirst(10).dropLast(2))))
            return try XCTUnwrap(String(data: data, encoding: .utf8))
        }.joined()
        XCTAssertEqual(decoded, dest.subject)
        XCTAssertTrue(mime.contains(payload.pdf.base64EncodedString(options: [.lineLength76Characters, .endLineWithCarriageReturn, .endLineWithLineFeed])))
        XCTAssertTrue(mime.components(separatedBy: "\r\n").allSatisfy { $0.utf8.count < 998 })
        if let dir = ProcessInfo.processInfo.environment["AGENTWATCH_REPORT_PREVIEW_DIR"] {
            try payload.mime.write(to: URL(fileURLWithPath: dir).appendingPathComponent("synthetic-report.eml"))
        }
    }
    func testRecipientValidationRejectsHeaderInjectionAmbiguityAndDuplicates() throws {
        for address in ["boss@example.test\r\nBcc: other@example.test", "Boss <boss@example.test>", "a..b@example.test", "a@example..test", "a@-example.test", "á@example.test"] {
            XCTAssertThrowsError(try destination(to: address))
        }
        XCTAssertThrowsError(try ReportMailDestination(accountKey: "test", from: "a@example.test", to: ["x@example.test"], cc: ["X@example.test"], subject: "Report"))
        XCTAssertThrowsError(try ReportMailDestination(accountKey: "test", from: "a@example.test", to: ["x@example.test"], subject: "Report\nBcc: other@example.test"))
    }
    func testDurablePreparePreservesMIMEAndMessageIDWhileDestinationChangeCreatesNewJob() throws {
        let store = GmailOutboxStore(root: try root()), report = try snapshot(), dest = try destination()
        let first = try store.prepare(snapshot: report, destination: dest)
        let second = try store.prepare(snapshot: report, destination: dest, now: Date().addingTimeInterval(1000))
        XCTAssertEqual(try ReportEncoding.encode(first), try ReportEncoding.encode(second))
        let other = try store.prepare(snapshot: report, destination: destination(to: "other@example.test"))
        XCTAssertNotEqual(other.id, first.id); XCTAssertNil(other.approval)
        XCTAssertEqual(try store.payload(for: first), try store.payload(for: second))
    }
    func testAcceptedReceiptPreventsAnotherSendAndUsesExactSavedMIME() async throws {
        let store = GmailOutboxStore(root: try root()), job = try prepared(store)
        let transport = ScriptedGoogleTransport([response(200, ["id": "gmail-id", "threadId": "thread-id"])])
        let service = GmailDeliveryService(api: GmailAPI(transport: transport), store: store, policyStore: ReportTeamPolicyStore(root: store.files.root.appendingPathComponent("test-policy")))
        let done = try await service.deliver(jobID: job.id, credential: credential())
        XCTAssertEqual(done.state, .accepted); XCTAssertEqual(done.gmailMessageID, "gmail-id")
        _ = try await service.deliver(jobID: job.id, credential: credential())
        let requests = await transport.requests(); XCTAssertEqual(requests.count, 1)
        XCTAssertEqual(requests[0].url?.absoluteString, "https://gmail.googleapis.com/gmail/v1/users/me/messages/send")
        let body = try GoogleWire.json(XCTUnwrap(requests[0].httpBody))
        XCTAssertEqual(body["raw"] as? String, ReportMailRenderer.base64URL(try store.payload(for: job)))
    }
    func testTimeoutNeverAutomaticallyResendsAndRequiresExplicitReconciliation() async throws {
        let store = GmailOutboxStore(root: try root()), job = try prepared(store)
        let transport = ScriptedGoogleTransport([.timeout])
        let service = GmailDeliveryService(api: GmailAPI(transport: transport), store: store, policyStore: ReportTeamPolicyStore(root: store.files.root.appendingPathComponent("test-policy")))
        do { _ = try await service.deliver(jobID: job.id, credential: credential()); XCTFail() } catch { }
        XCTAssertEqual(try store.read(job.id)?.state, .uncertain)
        do { _ = try await service.deliver(jobID: job.id, credential: credential()); XCTFail() } catch { }
        let requests = await transport.requests(); XCTAssertEqual(requests.count, 1)
        XCTAssertThrowsError(try store.approve(job.id, employeeID: "employee", expectedPayloadHash: job.payloadHash))
        XCTAssertThrowsError(try store.reconcile(job.id, employeeID: "employee", observedInSent: false, acceptsDuplicateRisk: false, note: "Checked"))
        let retry = try store.reconcile(job.id, employeeID: "employee", observedInSent: false, acceptsDuplicateRisk: true, note: "Checked Sent manually")
        XCTAssertEqual(retry.state, .prepared); XCTAssertNil(retry.approval); XCTAssertEqual(retry.messageID, job.messageID)
        XCTAssertThrowsError(try store.claim(job.id, owner: "retry"))
    }
    func testExpiredSendingLeaseBecomesUncertainAndCannotBeStolen() throws {
        let store = GmailOutboxStore(root: try root()), job = try prepared(store), now = Date()
        _ = try store.claim(job.id, owner: "first", now: now)
        XCTAssertThrowsError(try store.claim(job.id, owner: "second", now: now))
        XCTAssertThrowsError(try store.claim(job.id, owner: "third", now: now.addingTimeInterval(181)))
        XCTAssertEqual(try store.read(job.id)?.state, .uncertain)
        XCTAssertThrowsError(try store.finish(job.id, owner: "first", state: .accepted, messageID: "late-id"))
    }
    func testMalformedSuccessAndServerErrorAreUncertain() async throws {
        for reply in [response(200), response(503)] {
            let store = GmailOutboxStore(root: try root()), job = try prepared(store)
            let transport = ScriptedGoogleTransport([reply])
            do { _ = try await GmailDeliveryService(api: GmailAPI(transport: transport), store: store, policyStore: ReportTeamPolicyStore(root: store.files.root.appendingPathComponent("test-policy"))).deliver(jobID: job.id, credential: credential()); XCTFail() } catch { }
            XCTAssertEqual(try store.read(job.id)?.state, .uncertain)
        }
    }
    func testDefiniteQuotaRejectionPersistsBackoff() async throws {
        for reply in [response(429), response(403, ["error": ["errors": [["reason": "userRateLimitExceeded"]]]])] {
            let store = GmailOutboxStore(root: try root()), job = try prepared(store)
            let transport = ScriptedGoogleTransport([reply])
            do { _ = try await GmailDeliveryService(api: GmailAPI(transport: transport), store: store, policyStore: ReportTeamPolicyStore(root: store.files.root.appendingPathComponent("test-policy"))).deliver(jobID: job.id, credential: credential()); XCTFail() }
            catch { XCTAssertEqual(error as? GoogleServiceError, .rateLimited) }
            let saved = try XCTUnwrap(store.read(job.id)); XCTAssertEqual(saved.state, .failed)
            XCTAssertGreaterThan(try XCTUnwrap(saved.retryNotBefore), Date())
            XCTAssertThrowsError(try store.claim(job.id, owner: "too-early"))
        }
    }
    func testWrongAccountApprovalAndChangedPayloadFailBeforeNetwork() async throws {
        let dir = try root(), store = GmailOutboxStore(root: dir), job = try prepared(store)
        XCTAssertThrowsError(try store.approve(job.id, employeeID: "other", expectedPayloadHash: job.payloadHash))
        XCTAssertThrowsError(try store.approve(job.id, employeeID: "employee", expectedPayloadHash: "changed"))
        let transport = ScriptedGoogleTransport([]), service = GmailDeliveryService(api: GmailAPI(transport: transport), store: store, policyStore: ReportTeamPolicyStore(root: store.files.root.appendingPathComponent("test-policy")))
        do { _ = try await service.deliver(jobID: job.id, credential: credential(subject: "other")); XCTFail() }
        catch { XCTAssertEqual(error as? GoogleServiceError, .wrongAccount) }
        try Data("changed".utf8).write(to: dir.appendingPathComponent(job.id + ".eml"))
        do { _ = try await service.deliver(jobID: job.id, credential: credential()); XCTFail() } catch { }
        XCTAssertEqual(try store.read(job.id)?.state, .prepared)
        let requests = await transport.requests(); XCTAssertTrue(requests.isEmpty)
    }
    func testManualSentConfirmationDoesNotInventGmailReceipt() throws {
        let store = GmailOutboxStore(root: try root()), job = try prepared(store)
        _ = try store.claim(job.id, owner: "first")
        _ = try store.finish(job.id, owner: "first", state: .uncertain)
        let reconciled = try store.reconcile(job.id, employeeID: "employee", observedInSent: true, acceptsDuplicateRisk: false, note: "Matched recipients and report in Sent")
        XCTAssertEqual(reconciled.state, .manuallyConfirmed); XCTAssertNil(reconciled.gmailMessageID)
        XCTAssertEqual(reconciled.reconciliations.count, 1)
    }
    func testGmailRetryAfterIsPersistedWhenLongerThanLocalBackoff() async throws {
        let store = GmailOutboxStore(root: try root()), job = try prepared(store), before = Date()
        let transport = ScriptedGoogleTransport([.http(GoogleHTTPResponse(status: 429, headers: ["Retry-After": "7200"]))])
        do {
            _ = try await GmailDeliveryService(api: GmailAPI(transport: transport), store: store,
                policyStore: ReportTeamPolicyStore(root: store.files.root.appendingPathComponent("test-policy"))).deliver(jobID: job.id, credential: credential())
            XCTFail()
        } catch { XCTAssertEqual(error as? GoogleServiceError, .rateLimited) }
        XCTAssertGreaterThanOrEqual(try XCTUnwrap(store.read(job.id)?.retryNotBefore), before.addingTimeInterval(7200))
    }
    func testGmailFailureDoesNotChangeCompletedDriveReceiptOrPayload() async throws {
        let dir = try root(), report = try snapshot(), driveStore = DriveUploadStore(root: dir.appendingPathComponent("drive"))
        let drive = try driveStore.prepare(snapshot: report, destination: DriveDestination(accountKey: credential().accountKey, folderID: "folder", fileName: "report.pdf"),
                                          payload: DailyReportRenderer.pdf(report.report, revision: report.revision))
        _ = try driveStore.approve(jobID: drive.id, approver: "employee", folderPermissionHash: "synthetic-acl", expectedPayloadHash: drive.payloadHash)
        _ = try driveStore.claim(jobID: drive.id, owner: "test")
        _ = try driveStore.update(jobID: drive.id, owner: "test") { $0.fileID = "fixed-file"; $0.webViewLink = "https://drive.google.com/file/d/fixed-file/view"; $0.state = .uploaded; $0.leaseOwner = nil; $0.leaseUntil = nil }
        let before = try driveStore.read(drive.id), bytes = try driveStore.payload(for: drive)
        let mailStore = GmailOutboxStore(root: dir.appendingPathComponent("gmail"))
        let mail = try mailStore.prepare(snapshot: report, destination: destination())
        _ = try mailStore.approve(mail.id, employeeID: "employee", expectedPayloadHash: mail.payloadHash)
        let transport = ScriptedGoogleTransport([response(403)])
        do {
            _ = try await GmailDeliveryService(api: GmailAPI(transport: transport), store: mailStore,
                policyStore: ReportTeamPolicyStore(root: dir.appendingPathComponent("policy"))).deliver(jobID: mail.id, credential: credential())
            XCTFail()
        } catch { }
        XCTAssertEqual(try driveStore.read(drive.id), before); XCTAssertEqual(try driveStore.payload(for: drive), bytes)
        let requests = await transport.requests(); XCTAssertTrue(requests.allSatisfy { $0.url?.host == "gmail.googleapis.com" })
    }
}
