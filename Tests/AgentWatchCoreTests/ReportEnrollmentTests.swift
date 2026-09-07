import XCTest
@testable import AgentWatchCore

final class ReportEnrollmentTests: XCTestCase {
    private func root() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: url) }; return url
    }
    private func identity(_ hash: String = String(repeating: "a", count: 64), name: String = "Nhân viên mẫu") throws -> ReportEnrollmentIdentity {
        try ReportEnrollmentIdentity(enrollmentHash: hash, label: name)
    }
    private func folder(_ id: String = "folder-one", name: String = "Nhân viên mẫu") -> DriveFolderAccess {
        DriveFolderAccess(id: id, name: name, permissions: ["synthetic-owner"], permissionHash: "synthetic-acl", sharedDrive: false)
    }
    func testIdentityUsesExistingKeyButKeepsAuthenticationHashOutOfReportAndName() throws {
        let first = try identity(), renamed = try identity(name: "Tên mới")
        XCTAssertEqual(first.employeeID, renamed.employeeID)
        XCTAssertNotEqual(first.employeeID, try identity(String(repeating: "b", count: 64)).employeeID)
        XCTAssertFalse(first.employeeID.contains(String(repeating: "a", count: 64)))
        XCTAssertEqual(first.folderName, "Nhân viên mẫu")
        XCTAssertEqual(try identity(name: "Nhóm/An\nBE").folderName, "Nhóm-An BE")
        XCTAssertThrowsError(try identity("not-a-hash"))
    }
    func testBindingIsScopedByOrganizationEmployeeAndGoogleAccount() throws {
        let store = ReportFolderBindingStore(root: try root()), who = try identity()
        _ = try store.bind(organizationID: "org", identity: who, accountKey: "account-a", folder: folder())
        XCTAssertEqual(try store.read(organizationID: "org", employeeID: who.employeeID, accountKey: "account-a")?.folderID, "folder-one")
        XCTAssertNil(try store.read(organizationID: "org", employeeID: who.employeeID, accountKey: "account-b"))
        XCTAssertNil(try store.read(organizationID: "other-org", employeeID: who.employeeID, accountKey: "account-a"))
        XCTAssertThrowsError(try store.requireMatch(organizationID: "org", employeeID: who.employeeID, destination: DriveDestination(accountKey: "account-b", folderID: "folder-one", fileName: "report.pdf")))
    }
    func testRenameKeepsFolderIDAndRebindingCannotSilentlyRedirectKey() throws {
        let store = ReportFolderBindingStore(root: try root()), who = try identity()
        _ = try store.bind(organizationID: "org", identity: who, accountKey: "account", folder: folder())
        let again = try store.bind(organizationID: "org", identity: identity(name: "Tên mới"), accountKey: "account", folder: folder(name: "Đã đổi tên trên Drive"))
        XCTAssertEqual(again.folderID, "folder-one")
        XCTAssertThrowsError(try store.bind(organizationID: "org", identity: who, accountKey: "account", folder: folder("another-folder")))
        XCTAssertThrowsError(try store.bind(organizationID: "org", identity: identity(String(repeating: "b", count: 64)), accountKey: "account", folder: folder()))
        XCTAssertThrowsError(try store.requireMatch(organizationID: "org", employeeID: who.employeeID, destination: DriveDestination(accountKey: "account", folderID: "another-folder", fileName: "report.pdf")))
    }
    private func reply(_ code: Int, _ object: [String: Any] = [:]) -> ScriptedGoogleTransport.Reply {
        .http(GoogleHTTPResponse(status: code, body: try! JSONSerialization.data(withJSONObject: object)))
    }
    private func metadata(_ id: String, name: String, parent: String? = nil) -> ScriptedGoogleTransport.Reply {
        var value: [String: Any] = ["id": id, "name": name, "mimeType": "application/vnd.google-apps.folder", "capabilities": ["canAddChildren": true]]
        if let parent { value["parents"] = [parent] }; return reply(200, value)
    }
    private var acl: ScriptedGoogleTransport.Reply { reply(200, ["permissions": [["id": "owner", "type": "user", "role": "owner", "emailAddress": "test@example.test"]]]) }
    private var credential: GoogleCredential {
        GoogleCredential(clientID: "test.apps.googleusercontent.com", subject: "synthetic", email: "test@example.test", accessToken: "fake", refreshToken: nil,
                         expiresAt: Date().addingTimeInterval(3600), scopes: [GoogleScopes.driveFile])
    }
    func testEmployeeFolderUsesCompanyParentAndRecoversSameIDAfterRename() async throws {
        let dir = try root()
        let first = ScriptedGoogleTransport([metadata("company", name: "Reports"), acl, reply(200, ["ids": ["child"]]), reply(404),
            reply(200, ["id": "child"]), metadata("child", name: "Nhân viên mẫu", parent: "company"), acl])
        let creator = DriveFolderCreator(api: DriveAPI(transport: first), root: dir)
        _ = try await creator.create(name: "Nhân viên mẫu", credential: credential, parentID: "company", identityKey: "org|member")
        let requests = await first.requests()
        let body = try GoogleWire.json(XCTUnwrap(requests.first { $0.httpMethod == "POST" }?.httpBody))
        XCTAssertEqual(body["parents"] as? [String], ["company"])
        XCTAssertEqual(body["name"] as? String, "Nhân viên mẫu")
        let second = ScriptedGoogleTransport([metadata("company", name: "Reports"), acl, metadata("child", name: "Folder renamed", parent: "company"), acl])
        let restored = try await DriveFolderCreator(api: DriveAPI(transport: second), root: dir).create(name: "New key label", credential: credential, parentID: "company", identityKey: "org|member")
        XCTAssertEqual(restored.id, "child")
        let recovery = await second.requests(); XCTAssertTrue(recovery.allSatisfy { $0.httpMethod == "GET" })
    }
    func testEmployeeFolderMovedOutsideCompanyParentIsRejected() async throws {
        let transport = ScriptedGoogleTransport([metadata("child", name: "Employee", parent: "other-parent")])
        do { _ = try await DriveAPI(transport: transport).folder("child", credential: credential, expectedParentID: "company"); XCTFail() }
        catch { XCTAssertEqual(error as? GoogleServiceError, .conflict) }
    }
    func testBindSelectedChildWithoutParentVisibilityAndRestoreOnNextLaunch() async throws {
        let dir = try root(), who = try identity()
        let bindings = ReportFolderBindingStore(root: dir.appendingPathComponent("bindings"))
        // Google may omit parents when the caller only has access to the child.
        let transport = ScriptedGoogleTransport([metadata("child", name: "Employee only"), acl])
        let service = ReportFolderBindingService(api: DriveAPI(transport: transport), bindings: bindings,
            policy: ReportTeamPolicyStore(root: dir.appendingPathComponent("policy")))
        let saved = try await service.bind(folderID: "https://drive.google.com/drive/folders/child", organizationID: "org",
            identity: who, credential: credential, timeZone: "Asia/Ho_Chi_Minh")
        XCTAssertEqual(saved.folderID, "child")
        let restored = try ReportFolderBindingStore(root: bindings.files.root).read(organizationID: "org", employeeID: who.employeeID, accountKey: credential.accountKey)
        XCTAssertEqual(restored?.id, saved.id)
        XCTAssertEqual(restored?.folderID, saved.folderID)
        XCTAssertEqual(restored?.folderName, saved.folderName)
        XCTAssertEqual(try XCTUnwrap(restored).boundAt.timeIntervalSince1970, saved.boundAt.timeIntervalSince1970, accuracy: 0.001)
        let requests = await transport.requests()
        XCTAssertEqual(requests.map { $0.url?.path }, ["/drive/v3/files/child", "/drive/v3/files/child/permissions"])
        XCTAssertTrue(requests.allSatisfy { $0.httpMethod == "GET" })
        let fields = URLComponents(url: requests[0].url!, resolvingAgainstBaseURL: false)?.queryItems?.first { $0.name == "fields" }?.value
        XCTAssertFalse(try XCTUnwrap(fields).contains("parents"))
        XCTAssertThrowsError(try bindings.requireMatch(organizationID: "org", employeeID: who.employeeID,
            destination: DriveDestination(accountKey: credential.accountKey, folderID: "another-employee", fileName: "report.pdf")))
    }
    func testChildWithoutUploadPermissionDoesNotBindOrRequestParent() async throws {
        let dir = try root(), who = try identity()
        let bindings = ReportFolderBindingStore(root: dir.appendingPathComponent("bindings"))
        let transport = ScriptedGoogleTransport([reply(200, ["id": "child", "name": "Read only", "mimeType": "application/vnd.google-apps.folder", "capabilities": ["canAddChildren": false]])])
        let service = ReportFolderBindingService(api: DriveAPI(transport: transport), bindings: bindings,
            policy: ReportTeamPolicyStore(root: dir.appendingPathComponent("policy")))
        do {
            _ = try await service.bind(folderID: "child", organizationID: "org", identity: who, credential: credential, timeZone: "Asia/Ho_Chi_Minh")
            XCTFail("Read-only folder accepted")
        } catch { XCTAssertEqual(error as? GoogleServiceError, .permissionDenied) }
        XCTAssertNil(try bindings.read(organizationID: "org", employeeID: who.employeeID, accountKey: credential.accountKey))
        let requests = await transport.requests()
        XCTAssertEqual(requests.map { $0.url?.path }, ["/drive/v3/files/child"])
    }
    func testChildSelectionStillHonorsTeamFolderRestrictions() async throws {
        let dir = try root(), who = try identity()
        let policyStore = ReportTeamPolicyStore(root: dir.appendingPathComponent("policy"))
        let policy = ReportTeamPolicy(organizationID: "org", revision: 1, owner: "admin", timeZone: "Asia/Ho_Chi_Minh",
            employees: [ReportEmployeeAccess(employeeID: who.employeeID, googleAccountKeys: [credential.accountKey], recipients: [], driveFolderIDs: ["my-child"])],
            allowGmail: false, allowDrive: true, allowScheduledDelivery: false, allowNarrativeExport: false, retentionDays: 30,
            effectiveFrom: Date().addingTimeInterval(-60), expiresAt: Date().addingTimeInterval(3600))
        try policyStore.install(ReportEncoding.encode(policy), expectedHash: policy.digest, confirmedBy: "admin")
        let transport = ScriptedGoogleTransport([])
        let service = ReportFolderBindingService(api: DriveAPI(transport: transport), bindings: ReportFolderBindingStore(root: dir.appendingPathComponent("bindings")), policy: policyStore)
        do {
            _ = try await service.bind(folderID: "another-employee", organizationID: "org", identity: who, credential: credential, timeZone: "Asia/Ho_Chi_Minh")
            XCTFail("Folder outside team policy accepted")
        } catch { }
        let requests = await transport.requests()
        XCTAssertTrue(requests.isEmpty)
    }
}
