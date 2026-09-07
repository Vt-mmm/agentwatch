import XCTest
@testable import AgentWatchCore

final class GoogleSetupTests: XCTestCase {
    func testDesktopImportAndFolderNormalization() throws {
        let data = Data(#"{"installed":{"client_id":"test.apps.googleusercontent.com","client_secret":"synthetic"}}"#.utf8)
        XCTAssertEqual(try GoogleDesktopClientFile.parse(data).clientID, "test.apps.googleusercontent.com")
        for bad in [#"{"web":{"client_id":"test.apps.googleusercontent.com","client_secret":"synthetic"}}"#, "broken", "{}"] {
            XCTAssertThrowsError(try GoogleDesktopClientFile.parse(Data(bad.utf8)))
        }
        XCTAssertEqual(try GoogleDesktopClientFile.folderID(" https://drive.google.com/drive/u/0/folders/synthetic-folder, "), "synthetic-folder")
        XCTAssertEqual(try GoogleDesktopClientFile.folderID("synthetic-folder"), "synthetic-folder")
        XCTAssertThrowsError(try GoogleDesktopClientFile.folderID("https://evil.example/folders/synthetic"))
        XCTAssertThrowsError(try GoogleDesktopClientFile.folderID("https://drive.google.com/folders/a/extra"))
    }
    func testOAuthSecretRedactedFromVietnamesePromptAndGeneralText() {
        let secret = "GOCSPX-synthetic_secret_0123456789"
        let input = "client secret là " + secret + ", giúp tôi cấu hình"
        XCTAssertFalse(ReportPromptText.clean(input).contains(secret))
        XCTAssertFalse(ShareText.clean(input).contains(secret))
        XCTAssertTrue(ReportPromptText.clean(input).contains("giúp tôi cấu hình"))
    }
    func testPickerUsesDriveOnlyAndValidatesSelection() throws {
        let attempt = try GoogleOAuthAttempt(redirectURI: "http://127.0.0.1:40000/oauth/callback", scopes: [GoogleScopes.driveFile], folderPicker: true)
        let url = try attempt.authorizationURL(configuration: GoogleOAuthConfiguration(clientID: "test.apps.googleusercontent.com"), loginHint: "employee@example.test")
        let query = URLComponents(url: url, resolvingAgainstBaseURL: false)!.queryItems!
        XCTAssertEqual(query.first { $0.name == "scope" }?.value, GoogleScopes.driveFile)
        XCTAssertEqual(query.first { $0.name == "prompt" }?.value, "consent")
        XCTAssertEqual(query.first { $0.name == "trigger_onepick" }?.value, "true")
        XCTAssertEqual(query.first { $0.name == "include_granted_scopes" }?.value, "false")
        let base = attempt.redirectURI + "?state=\(attempt.state)&code=fake"
        XCTAssertEqual(try attempt.pickedFolderID(callback: URL(string: base + "&picked_file_ids=folder-1")!), "folder-1")
        for tail in ["", "&picked_file_ids=a,b", "&picked_file_ids=a&picked_file_ids=b", "&picked_file_ids=../a"] {
            XCTAssertThrowsError(try attempt.pickedFolderID(callback: URL(string: base + tail)!))
        }
        XCTAssertThrowsError(try GoogleOAuthAttempt(redirectURI: attempt.redirectURI, scopes: GoogleScopes.identity.union([GoogleScopes.driveFile]), folderPicker: true))
    }
    func testPickerAccountVerificationDoesNotReplaceGmailCredential() async throws {
        let account = GoogleCredential(clientID: "test.apps.googleusercontent.com", subject: "subject", email: "employee@example.test", accessToken: "original", refreshToken: "keep-me", expiresAt: Date().addingTimeInterval(3600), scopes: GoogleScopes.supported)
        let attempt = try GoogleOAuthAttempt(redirectURI: "http://127.0.0.1:40000/oauth/callback", scopes: [GoogleScopes.driveFile], folderPicker: true)
        for email in [account.email, "wrong@example.test"] {
            let transport = ScriptedGoogleTransport([
                .http(GoogleHTTPResponse(status: 200, body: try JSONSerialization.data(withJSONObject: ["access_token": "picker-only", "expires_in": 3600, "scope": GoogleScopes.driveFile]))),
                .http(GoogleHTTPResponse(status: 200, body: try JSONSerialization.data(withJSONObject: ["user": ["emailAddress": email]])))])
            do {
                let grant = try await GoogleOAuthClient(transport: transport).exchange(code: "fake", attempt: attempt,
                    configuration: GoogleOAuthConfiguration(clientID: account.clientID), pickerAccount: account)
                XCTAssertEqual(email, account.email)
                XCTAssertEqual(grant.accountKey, account.accountKey)
                XCTAssertNil(grant.refreshToken)
                XCTAssertEqual(grant.scopes, [GoogleScopes.driveFile])
            } catch { XCTAssertEqual(error as? GoogleServiceError, .wrongAccount); XCTAssertNotEqual(email, account.email) }
            XCTAssertEqual(account.refreshToken, "keep-me")
            XCTAssertTrue(account.scopes.contains(GoogleScopes.gmailSend))
        }
    }
}
