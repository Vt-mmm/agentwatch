import Foundation
import CryptoKit
import Security

public enum GoogleScopes {
    public static let identity: Set<String> = ["openid", "email"]
    public static let driveFile = "https://www.googleapis.com/auth/drive.file"
    public static let gmailSend = "https://www.googleapis.com/auth/gmail.send"
    public static let supported = identity.union([driveFile, gmailSend])
}

public struct GoogleOAuthConfiguration: Sendable {
    public let clientID: String
    public let clientSecret: String?
    public init(clientID: String, clientSecret: String? = nil) { self.clientID = clientID; self.clientSecret = clientSecret }
}
public struct GoogleOAuthAttempt: Sendable {
    public let state: String
    public let verifier: String
    public let redirectURI: String
    public let scopes: Set<String>
    public let folderPicker: Bool
    public init(redirectURI: String, scopes: Set<String>, folderPicker: Bool = false) throws {
        guard let redirect = URLComponents(string: redirectURI), redirect.scheme == "http", redirect.host == "127.0.0.1",
              let port = redirect.port, port > 0, redirect.user == nil, redirect.password == nil,
              redirect.query == nil, redirect.fragment == nil,
              scopes.isSubset(of: GoogleScopes.supported), (folderPicker ? scopes == [GoogleScopes.driveFile] : GoogleScopes.identity.isSubset(of: scopes)) else {
            throw GoogleServiceError.invalidConfiguration
        }
        self.redirectURI = redirectURI; self.scopes = scopes; self.folderPicker = folderPicker
        state = try Self.random(); verifier = try Self.random()
    }
    public var challenge: String { Self.base64URL(Data(SHA256.hash(data: Data(verifier.utf8)))) }
    public func authorizationURL(configuration: GoogleOAuthConfiguration, loginHint: String? = nil) throws -> URL {
        guard configuration.clientID.hasSuffix(".apps.googleusercontent.com"), !configuration.clientID.contains(where: \.isWhitespace) else { throw GoogleServiceError.invalidConfiguration }
        var components = URLComponents(string: "https://accounts.google.com/o/oauth2/v2/auth")!
        components.queryItems = [
            URLQueryItem(name: "client_id", value: configuration.clientID), URLQueryItem(name: "redirect_uri", value: redirectURI),
            URLQueryItem(name: "response_type", value: "code"), URLQueryItem(name: "scope", value: scopes.sorted().joined(separator: " ")),
            URLQueryItem(name: "code_challenge", value: challenge), URLQueryItem(name: "code_challenge_method", value: "S256"),
            URLQueryItem(name: "state", value: state), URLQueryItem(name: "access_type", value: "offline"),
            URLQueryItem(name: "prompt", value: "consent select_account")]
        if let loginHint, !loginHint.isEmpty { components.queryItems?.append(URLQueryItem(name: "login_hint", value: loginHint)) }
        if folderPicker {
            components.queryItems?.removeAll { $0.name == "prompt" }
            components.queryItems? += [URLQueryItem(name: "prompt", value: "consent"),
                URLQueryItem(name: "trigger_onepick", value: "true"), URLQueryItem(name: "allow_multiple", value: "false"),
                URLQueryItem(name: "allow_folder_selection", value: "true"),
                URLQueryItem(name: "mimetypes", value: "application/vnd.google-apps.folder"),
                URLQueryItem(name: "include_granted_scopes", value: "false")]
        }
        return components.url!
    }
    public func authorizationCode(callback: URL) throws -> String {
        guard let expected = URLComponents(string: redirectURI), let actual = URLComponents(url: callback, resolvingAgainstBaseURL: false),
              actual.scheme == expected.scheme, actual.host == expected.host, actual.port == expected.port, actual.path == expected.path,
              actual.user == nil, actual.password == nil, actual.fragment == nil else { throw GoogleServiceError.invalidCallback }
        let items = actual.queryItems ?? []
        guard items.filter({ $0.name == "state" }).count == 1,
              items.first(where: { $0.name == "state" })?.value == state else { throw GoogleServiceError.invalidCallback }
        if items.contains(where: { $0.name == "error" }) { throw GoogleServiceError.cancelled }
        guard items.filter({ $0.name == "code" }).count == 1,
              let code = items.first(where: { $0.name == "code" })?.value, !code.isEmpty else { throw GoogleServiceError.invalidCallback }
        return code
    }
    public func pickedFolderID(callback: URL) throws -> String {
        _ = try authorizationCode(callback: callback)
        let items = URLComponents(url: callback, resolvingAgainstBaseURL: false)?.queryItems ?? []
        guard folderPicker, items.filter({ $0.name == "picked_file_ids" }).count == 1,
              let id = items.first(where: { $0.name == "picked_file_ids" })?.value, DriveAPI.validID(id) else {
            throw GoogleServiceError.invalidCallback
        }
        return id
    }
    public static func base64URL(_ data: Data) -> String {
        data.base64EncodedString().replacingOccurrences(of: "+", with: "-").replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: "=", with: "")
    }
    private static func random() throws -> String {
        var bytes = [UInt8](repeating: 0, count: 32)
        guard SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes) == errSecSuccess else { throw GoogleServiceError.invalidConfiguration }
        return base64URL(Data(bytes))
    }
}

public struct GoogleCredential: Codable, Sendable {
    public let clientID: String
    public let subject: String
    public let email: String
    public var accessToken: String
    public var refreshToken: String?
    public var expiresAt: Date
    public var scopes: Set<String>
    public var accountKey: String { ReportEncoding.digest(Data((clientID + "|" + subject).utf8)) }
}

public protocol GoogleCredentialStorage: Sendable {
    func save(_ credential: GoogleCredential) throws
    func load(accountKey: String) throws -> GoogleCredential?
    func remove(accountKey: String) throws
}

public struct GoogleKeychainStorage: GoogleCredentialStorage {
    private let service = "com.vtamm.agentwatch.google-oauth"
    public init() {}
    public func save(_ credential: GoogleCredential) throws {
        let data = try JSONEncoder().encode(credential)
        let query: [String: Any] = [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service,
                                    kSecAttrAccount as String: credential.accountKey]
        let update = SecItemUpdate(query as CFDictionary, [kSecValueData as String: data] as CFDictionary)
        if update == errSecItemNotFound {
            var item = query; item[kSecValueData as String] = data
            item[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
            guard SecItemAdd(item as CFDictionary, nil) == errSecSuccess else { throw GoogleServiceError.storage("Không lưu được phiên Google trong Keychain.") }
        } else if update != errSecSuccess { throw GoogleServiceError.storage("Không cập nhật được Keychain Google.") }
    }
    public func load(accountKey: String) throws -> GoogleCredential? {
        let query: [String: Any] = [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service,
                                    kSecAttrAccount as String: accountKey, kSecReturnData as String: true, kSecMatchLimit as String: kSecMatchLimitOne]
        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess, let data = item as? Data else { throw GoogleServiceError.storage("Không đọc được phiên Google từ Keychain.") }
        return try JSONDecoder().decode(GoogleCredential.self, from: data)
    }
    public func remove(accountKey: String) throws {
        let query: [String: Any] = [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service, kSecAttrAccount as String: accountKey]
        let status = SecItemDelete(query as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else { throw GoogleServiceError.storage("Không xóa được phiên Google trong Keychain.") }
    }
}

public struct GoogleOAuthClient: Sendable {
    public let transport: any GoogleHTTPTransport
    public init(transport: any GoogleHTTPTransport = GoogleURLSessionTransport()) { self.transport = transport }
    public func exchange(code: String, attempt: GoogleOAuthAttempt, configuration: GoogleOAuthConfiguration, now: Date = Date(), pickerAccount: GoogleCredential? = nil) async throws -> GoogleCredential {
        guard attempt.folderPicker == (pickerAccount != nil) else { throw GoogleServiceError.invalidConfiguration }
        if let pickerAccount, pickerAccount.clientID != configuration.clientID { throw GoogleServiceError.wrongAccount }
        var fields = ["client_id": configuration.clientID, "code": code, "code_verifier": attempt.verifier,
                      "redirect_uri": attempt.redirectURI, "grant_type": "authorization_code"]
        if let secret = configuration.clientSecret { fields["client_secret"] = secret }
        let response = try await transport.send(GoogleWire.request(url: URL(string: "https://oauth2.googleapis.com/token")!, method: "POST", body: GoogleWire.form(fields), contentType: "application/x-www-form-urlencoded"))
        guard response.status == 200 else { throw GoogleServiceError.from(status: response.status) }
        let payload = try GoogleWire.json(response.body)
        guard let access = payload["access_token"] as? String, !access.isEmpty,
              let expires = payload["expires_in"] as? Double, expires > 0,
              let scopeText = payload["scope"] as? String else { throw GoogleServiceError.invalidResponse }
        let granted = normalizedScopes(scopeText)
        guard attempt.scopes.isSubset(of: granted) else { throw GoogleServiceError.missingScope }
        if let account = pickerAccount {
            let response = try await transport.send(GoogleWire.request(url: URL(string: "https://www.googleapis.com/drive/v3/about?fields=user(emailAddress)")!, token: access))
            guard response.status == 200 else { throw GoogleServiceError.from(status: response.status) }
            let user = try GoogleWire.json(response.body)["user"] as? [String: Any]
            guard let email = user?["emailAddress"] as? String,
                  email.caseInsensitiveCompare(account.email) == .orderedSame else { throw GoogleServiceError.wrongAccount }
            // Ephemeral drive-only grant; never replace the connected Gmail refresh token.
            return GoogleCredential(clientID: account.clientID, subject: account.subject, email: account.email,
                accessToken: access, refreshToken: nil, expiresAt: now.addingTimeInterval(expires), scopes: granted)
        }
        let identity = try await transport.send(GoogleWire.request(url: URL(string: "https://openidconnect.googleapis.com/v1/userinfo")!, token: access))
        guard identity.status == 200 else { throw GoogleServiceError.from(status: identity.status) }
        let user = try GoogleWire.json(identity.body)
        guard let subject = user["sub"] as? String, !subject.isEmpty,
              let email = user["email"] as? String, email.contains("@"), user["email_verified"] as? Bool == true else { throw GoogleServiceError.invalidResponse }
        return GoogleCredential(clientID: configuration.clientID, subject: subject, email: email, accessToken: access,
                                refreshToken: payload["refresh_token"] as? String, expiresAt: now.addingTimeInterval(expires), scopes: granted)
    }
    public func refresh(_ credential: GoogleCredential, configuration: GoogleOAuthConfiguration, now: Date = Date()) async throws -> GoogleCredential {
        guard credential.clientID == configuration.clientID, let refresh = credential.refreshToken else { throw GoogleServiceError.authenticationRequired }
        var fields = ["client_id": configuration.clientID, "refresh_token": refresh, "grant_type": "refresh_token"]
        if let secret = configuration.clientSecret { fields["client_secret"] = secret }
        let response = try await transport.send(GoogleWire.request(url: URL(string: "https://oauth2.googleapis.com/token")!, method: "POST", body: GoogleWire.form(fields), contentType: "application/x-www-form-urlencoded"))
        guard response.status == 200 else { throw response.status == 400 ? GoogleServiceError.authenticationRequired : GoogleServiceError.from(status: response.status) }
        let payload = try GoogleWire.json(response.body)
        guard let access = payload["access_token"] as? String, !access.isEmpty, let expires = payload["expires_in"] as? Double, expires > 0 else { throw GoogleServiceError.invalidResponse }
        var result = credential; result.accessToken = access; result.expiresAt = now.addingTimeInterval(expires)
        if let refresh = payload["refresh_token"] as? String { result.refreshToken = refresh }
        if let scope = payload["scope"] as? String { result.scopes = normalizedScopes(scope) }
        return result
    }
    private func normalizedScopes(_ text: String) -> Set<String> {
        Set(text.split(separator: " ").map { $0 == "https://www.googleapis.com/auth/userinfo.email" ? "email" : String($0) })
    }
}
