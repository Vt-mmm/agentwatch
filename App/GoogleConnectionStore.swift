import Foundation
import SwiftUI
import AgentWatchCore

@Observable
@MainActor
final class GoogleConnectionStore {
    var clientID: String { didSet { UserDefaults.standard.set(clientID, forKey: "google.clientID") } }
    var expectedEmail: String { didSet { UserDefaults.standard.set(expectedEmail, forKey: "google.expectedEmail") } }
    var email: String
    var accountKey: String
    var isConnecting = false
    private let storage = GoogleKeychainStorage()
    init() {
        clientID = UserDefaults.standard.string(forKey: "google.clientID") ?? ""
        expectedEmail = UserDefaults.standard.string(forKey: "google.expectedEmail") ?? ""
        email = UserDefaults.standard.string(forKey: "google.email") ?? ""
        accountKey = UserDefaults.standard.string(forKey: "google.accountKey") ?? ""
    }
    func connect(clientSecret: String, enableGmail: Bool = false) async throws {
        guard !isConnecting else { return }
        isConnecting = true; defer { isConnecting = false }
        if !clientSecret.isEmpty { try GoogleClientSecretStore.save(clientSecret, clientID: clientID) }
        let configuration = GoogleOAuthConfiguration(clientID: clientID, clientSecret: try GoogleClientSecretStore.load(clientID: clientID))
        let scopes = GoogleScopes.identity.union([GoogleScopes.driveFile]).union(enableGmail ? [GoogleScopes.gmailSend] : [])
        let credential = try await GoogleBrowserAuthorization.authorize(configuration: configuration, scopes: scopes, loginHint: expectedEmail)
        guard expectedEmail.isEmpty || credential.email.caseInsensitiveCompare(expectedEmail.trimmingCharacters(in: .whitespacesAndNewlines)) == .orderedSame else { throw GoogleServiceError.wrongAccount }
        try storage.save(credential)
        accountKey = credential.accountKey; email = credential.email
        UserDefaults.standard.set(accountKey, forKey: "google.accountKey")
        UserDefaults.standard.set(email, forKey: "google.email")
    }
    func importClient(from url: URL) throws {
        let config = try GoogleDesktopClientFile.parse(Data(contentsOf: url))
        try GoogleClientSecretStore.save(config.clientSecret!, clientID: config.clientID)
        clientID = config.clientID
    }
    func pickFolder() async throws -> DriveFolderAccess {
        guard !isConnecting else { throw GoogleServiceError.cancelled }
        isConnecting = true; defer { isConnecting = false }
        let account = try await credential(requiring: [GoogleScopes.driveFile])
        let config = GoogleOAuthConfiguration(clientID: clientID, clientSecret: try GoogleClientSecretStore.load(clientID: clientID))
        let picked = try await GoogleBrowserAuthorization.pickFolder(configuration: config, account: account)
        // Recheck that the durable connected credential can access the new grant.
        let current = try await credential(requiring: [GoogleScopes.driveFile])
        guard current.accountKey == account.accountKey else { throw GoogleServiceError.wrongAccount }
        return try await DriveAPI().folder(picked.id, credential: current)
    }
    func credential(requiring scopes: Set<String>) async throws -> GoogleCredential {
        guard var credential = try storage.load(accountKey: accountKey), credential.clientID == clientID else { throw GoogleServiceError.authenticationRequired }
        if credential.expiresAt <= Date().addingTimeInterval(90) {
            let config = GoogleOAuthConfiguration(clientID: clientID, clientSecret: try GoogleClientSecretStore.load(clientID: clientID))
            credential = try await GoogleOAuthClient().refresh(credential, configuration: config)
            try storage.save(credential)
        }
        guard scopes.isSubset(of: credential.scopes) else { throw GoogleServiceError.missingScope }
        return credential
    }
    func disconnectLocally() throws {
        try storage.remove(accountKey: accountKey)
        accountKey = ""; email = ""
        UserDefaults.standard.removeObject(forKey: "google.accountKey"); UserDefaults.standard.removeObject(forKey: "google.email")
    }
}
