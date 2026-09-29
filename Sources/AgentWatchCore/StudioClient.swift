import Foundation
import CryptoKit

public enum StudioError: String, Error, LocalizedError, Sendable, Equatable, Codable {
    case invalidOrigin, invalidKey, incompatibleVersion, invalidResponse, redirectDenied
    case permissionDenied, quotaExceeded, rateLimited, serverUnavailable, upstreamUnavailable, offline
    case storage, keychainApprovalRequired, identityChanged, disconnectFirst

    public var errorDescription: String? {
        switch self {
        case .invalidOrigin: "Nhập địa chỉ gốc của API Studio, không kèm đường dẫn hoặc key. Cần HTTPS; HTTP chỉ dùng với 127.0.0.1 hoặc [::1] để thử local."
        case .invalidKey: "Key không hợp lệ, hết hạn hoặc đã bị thu hồi. Kiểm tra lại key nhân viên."
        case .incompatibleVersion: "Phiên bản API Studio chưa tương thích với Agent Watch này."
        case .invalidResponse: "Studio trả về dữ liệu không hợp lệ. Chưa thể xác nhận kết nối."
        case .redirectDenied: "Địa chỉ này chuyển hướng. Nhập trực tiếp API origin của Studio; key không được gửi theo chuyển hướng."
        case .permissionDenied: "Key chưa có quyền truy cập phần dữ liệu này."
        case .quotaExceeded: "Hạn mức Studio đã hết."
        case .rateLimited: "Studio đang giới hạn lượt gọi. Thử lại sau."
        case .serverUnavailable: "Studio hiện chưa sẵn sàng. Thử kiểm tra lại sau."
        case .upstreamUnavailable: "Nhà cung cấp AI hiện chưa sẵn sàng."
        case .offline: "Chưa kết nối được Studio. Dữ liệu cũ, nếu có, chưa được cập nhật."
        case .keychainApprovalRequired: "macOS cần cho phép đọc key Studio. Bấm Cho phép Keychain ở phần kết nối."
        case .storage: "Không đọc hoặc lưu được key trong Keychain. Kiểm tra trạng thái mở khóa của máy rồi thử lại."
        case .identityChanged: "Danh tính server trả về đã thay đổi. Ngắt kết nối và kiểm tra lại tài khoản trước khi kết nối lại."
        case .disconnectFirst: "Ngắt kết nối hiện tại trước khi chuyển sang Studio hoặc tài khoản khác."
        }
    }
}

public struct StudioOrigin: Codable, Hashable, Sendable {
    public let value: String
    public init(_ input: String) throws {
        let text = input.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, text.utf8.count <= 2048,
              !text.contains(where: { $0.isWhitespace || $0.asciiValue.map { $0 < 32 || $0 == 127 } == true }),
              !text.contains("\\"), !text.contains("%"),
              var parts = URLComponents(string: text), let scheme = parts.scheme?.lowercased(),
              let host = parts.host?.lowercased(), !host.isEmpty,
              parts.user == nil, parts.password == nil, parts.query == nil, parts.fragment == nil,
              parts.path.isEmpty || parts.path == "/",
              parts.port.map({ (1...65535).contains($0) }) ?? true,
              scheme == "https" || (scheme == "http" && ["127.0.0.1", "::1", "[::1]"].contains(host))
        else { throw StudioError.invalidOrigin }
        parts.scheme = scheme; parts.host = host; parts.path = ""
        if parts.port == (scheme == "https" ? 443 : 80) { parts.port = nil }
        guard let url = parts.url, url.host != nil else { throw StudioError.invalidOrigin }
        value = url.absoluteString
    }
    public init(from decoder: any Decoder) throws { try self.init(decoder.singleValueContainer().decode(String.self)) }
    public func encode(to encoder: any Encoder) throws { var c = encoder.singleValueContainer(); try c.encode(value) }
    public func url(path: String) -> URL { URL(string: value)!.appendingPathComponent(path) }
    public func contains(_ url: URL) -> Bool {
        guard var components = URLComponents(url: url, resolvingAgainstBaseURL: false),
              components.user == nil, components.password == nil else { return false }
        components.path = ""; components.query = nil; components.fragment = nil
        return components.string.flatMap { try? StudioOrigin($0) } == self
    }
    public func profileID(orgID: UUID, ownerID: UUID) -> String {
        let input = "agentwatch-studio-profile-v1\u{0}\(value)\u{0}\(orgID.uuidString.lowercased())\u{0}\(ownerID.uuidString.lowercased())"
        return SHA256.hash(data: Data(input.utf8)).map { String(format: "%02x", $0) }.joined()
    }
}

public struct StudioUser: Codable, Equatable, Sendable, Identifiable {
    public let id: UUID
    public let displayName: String
    public let role: String
    public let active: Bool
    public let version: Int64
    public var teamID: UUID? = nil
    public var teamName: String? = nil
    enum CodingKeys: String, CodingKey { case id, displayName = "display_name", role, active, version, teamID = "team_id", teamName = "team_name" }
}
public struct StudioIdentity: Codable, Equatable, Sendable {
    public let user: StudioUser
    public let orgID: UUID
    public let apiVersion: String
    enum CodingKeys: String, CodingKey { case user, orgID = "org_id", apiVersion = "api_version" }
}
public struct StudioCapabilities: Decodable, Equatable, Sendable {
    public let apiVersion: String
    public let protocols: [String]
    public let auth: [String]
    enum CodingKeys: String, CodingKey { case apiVersion = "api_version", protocols, auth }
}
public struct StudioModel: Codable, Equatable, Sendable, Identifiable {
    public let id: String
    public let displayName: String
    public let ownedBy: String
    public let nativeProtocol: String
    public var providerModel: String? = nil
    public var clientModel: String? = nil
    public var cliModelID: String { clientModel ?? id }
    public var maxOutputTokens: Int64? = nil
    public var outputAccounting: String? = nil
    public var contextMode: String? = nil
    enum CodingKeys: String, CodingKey {
        case id, displayName = "display_name", ownedBy = "owned_by", nativeProtocol = "protocol"
        case providerModel = "provider_model_id", maxOutputTokens = "max_output_tokens"
        case clientModel = "client_model_id"
        case outputAccounting = "output_accounting", contextMode = "context_mode"
    }
}
public enum StudioModelAccess: Equatable, Sendable {
    case available([StudioModel]), unavailable(StudioError)
}
public struct StudioConnectionSnapshot: Equatable, Sendable {
    public let identity: StudioIdentity
    public let capabilities: StudioCapabilities
    public let models: StudioModelAccess
    public let observedAt: Date
    public init(identity: StudioIdentity, capabilities: StudioCapabilities, models: StudioModelAccess, observedAt: Date = Date()) {
        self.identity = identity; self.capabilities = capabilities; self.models = models; self.observedAt = observedAt
    }
}

public struct StudioHTTPResponse: Sendable {
    public let status: Int
    public let contentType: String
    public let body: Data
    public init(status: Int, contentType: String = "application/json", body: Data) {
        self.status = status; self.contentType = contentType; self.body = body
    }
}
public protocol StudioHTTPTransport: Sendable {
    func send(_ request: URLRequest, origin: StudioOrigin) async throws -> StudioHTTPResponse
}

/// Uses only the chosen origin. No cookies, cached HTTP credentials, redirects,
/// discovery URLs or plaintext diagnostics can carry an employee key elsewhere.
public final class StudioURLSessionTransport: NSObject, StudioHTTPTransport, URLSessionTaskDelegate, @unchecked Sendable {
    public override init() { super.init() }
    public func send(_ request: URLRequest, origin: StudioOrigin) async throws -> StudioHTTPResponse {
        guard let url = request.url, origin.contains(url) else { throw StudioError.invalidOrigin }
        let config = URLSessionConfiguration.ephemeral
        config.httpCookieStorage = nil; config.httpCookieAcceptPolicy = .never
        config.urlCredentialStorage = nil; config.urlCache = nil
        config.requestCachePolicy = .reloadIgnoringLocalCacheData
        config.timeoutIntervalForRequest = 15; config.timeoutIntervalForResource = 20
        let session = URLSession(configuration: config, delegate: self, delegateQueue: nil)
        defer { session.invalidateAndCancel() }
        let (stream, response) = try await session.bytes(for: request)
        guard let http = response as? HTTPURLResponse, let responseURL = http.url, origin.contains(responseURL),
              http.expectedContentLength <= StudioClient.maxResponseBytes else { throw StudioError.invalidResponse }
        // 304 is a conditional-read result, not a redirect. The caller validates its cached value.
        if http.statusCode != 304, (300..<400).contains(http.statusCode) { throw StudioError.redirectDenied }
        var body = Data()
        for try await byte in stream {
            guard body.count < StudioClient.maxResponseBytes else { throw StudioError.invalidResponse }
            body.append(byte)
        }
        return StudioHTTPResponse(status: http.statusCode, contentType: http.value(forHTTPHeaderField: "Content-Type") ?? "", body: body)
    }
    public func urlSession(_ session: URLSession, task: URLSessionTask,
                           willPerformHTTPRedirection response: HTTPURLResponse, newRequest request: URLRequest,
                           completionHandler: @escaping (URLRequest?) -> Void) { completionHandler(nil) }
}

public protocol StudioConnecting: Sendable {
    func connect(origin: StudioOrigin, key: String) async throws -> StudioConnectionSnapshot
}
public struct StudioClient: StudioConnecting {
    private struct Failure: Decodable { struct Detail: Decodable { let code: String }; let error: Detail }
    public static let maxResponseBytes = 1_048_576
    private let transport: any StudioHTTPTransport
    public init(transport: any StudioHTTPTransport = StudioURLSessionTransport()) { self.transport = transport }

    public static func validKey(_ value: String) -> Bool {
        !value.isEmpty && value.utf8.count <= 4096 && value.utf8.allSatisfy {
            (65...90).contains($0) || (97...122).contains($0) || (48...57).contains($0) || $0 == 45 || $0 == 95
        }
    }
    public func connect(origin: StudioOrigin, key: String) async throws -> StudioConnectionSnapshot {
        guard Self.validKey(key) else { throw StudioError.invalidKey }
        let capabilities: StudioCapabilities = try await get(origin, "studio/v1/capabilities", key: nil)
        guard capabilities.apiVersion == "studio/v1", capabilities.auth.contains("bearer") else { throw StudioError.incompatibleVersion }
        let identity: StudioIdentity = try await get(origin, "studio/v1/me", key: key)
        guard identity.apiVersion == "studio/v1" else { throw StudioError.incompatibleVersion }
        guard identity.user.active, identity.user.version > 0,
              ["owner", "admin", "viewer", "member"].contains(identity.user.role),
              !identity.user.displayName.isEmpty, identity.user.displayName.utf8.count <= 120 else { throw StudioError.invalidResponse }
        let models: StudioModelAccess
        do {
            struct List: Decodable {
                let object: String; let data: [StudioModel]; let admissionRequired: Bool
                enum CodingKeys: String, CodingKey { case object, data, admissionRequired = "admission_required" }
            }
            let list: List = try await get(origin, "v1/models", key: key)
            guard list.object == "list", list.admissionRequired, list.data.count <= 1000,
                  Set(list.data.map(\.id)).count == list.data.count,
                  list.data.allSatisfy({ !$0.id.isEmpty && $0.id.utf8.count <= 160 &&
                      (($0.ownedBy == "claude" && $0.nativeProtocol == "messages") || ($0.ownedBy == "codex" && $0.nativeProtocol == "responses")) })
            else { throw StudioError.invalidResponse }
            models = .available(list.data)
        } catch let error as StudioError {
            if [.invalidKey, .incompatibleVersion, .redirectDenied, .invalidResponse].contains(error) { throw error }
            models = .unavailable(error)
        }
        return StudioConnectionSnapshot(identity: identity, capabilities: capabilities, models: models)
    }
    public func configuration(origin: StudioOrigin, key: String, previous: StudioManifest?) async throws -> StudioManifest {
        guard Self.validKey(key) else { throw StudioError.invalidKey }
        var request = URLRequest(url: origin.url(path: "studio/v1/client-config"))
        request.setValue("Bearer " + key, forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        if let previous { request.setValue("\"" + previous.revision + "\"", forHTTPHeaderField: "If-None-Match") }
        let response = try await transport.send(request, origin: origin)
        if response.status == 304 {
            guard let previous else { throw StudioError.invalidResponse }
            try previous.validate(); return previous
        }
        if response.status == 401 { throw StudioError.invalidKey }
        if response.status == 403 { throw StudioError.permissionDenied }
        if response.status == 404 { throw StudioError.incompatibleVersion }
        if response.status == 429 { throw StudioError.rateLimited }
        if (300..<400).contains(response.status) { throw StudioError.redirectDenied }
        guard response.status == 200 else { throw StudioError.serverUnavailable }
        guard response.body.count <= Self.maxResponseBytes,
              response.contentType.split(separator: ";").first?.trimmingCharacters(in: .whitespaces) == "application/json" else { throw StudioError.invalidResponse }
        let value: StudioManifest
        do { value = try Self.apiDecoder().decode(StudioManifest.self, from: response.body) }
        catch { throw StudioError.invalidResponse }
        try value.validate(); return value
    }
    func get<T: Decodable>(_ origin: StudioOrigin, _ path: String, key: String?, query: [URLQueryItem] = []) async throws -> T {
        if let key, !Self.validKey(key) { throw StudioError.invalidKey }
        var components = URLComponents(url: origin.url(path: path), resolvingAgainstBaseURL: false)!
        if !query.isEmpty { components.queryItems = query }
        var request = URLRequest(url: components.url!)
        request.httpMethod = "GET"; request.setValue("application/json", forHTTPHeaderField: "Accept")
        if let key { request.setValue("Bearer " + key, forHTTPHeaderField: "Authorization") }
        do {
            let response = try await transport.send(request, origin: origin)
            if (300..<400).contains(response.status) { throw StudioError.redirectDenied }
            guard response.body.count <= Self.maxResponseBytes else { throw StudioError.invalidResponse }
            guard response.status == 200 else {
                let code = (try? JSONDecoder().decode(Failure.self, from: response.body))?.error.code ?? ""
                switch response.status {
                case 400: throw code == "key_target_unavailable" ? StudioError.permissionDenied : StudioError.invalidResponse
                case 401: throw StudioError.invalidKey
                case 403: throw StudioError.permissionDenied
                case 429: throw code == "token_quota_exhausted" ? StudioError.quotaExceeded : StudioError.rateLimited
                default: throw code.hasPrefix("upstream_") ? StudioError.upstreamUnavailable : StudioError.serverUnavailable
                }
            }
            guard response.contentType.split(separator: ";").first?.trimmingCharacters(in: .whitespaces).lowercased() == "application/json" else { throw StudioError.invalidResponse }
            do { return try Self.apiDecoder().decode(T.self, from: response.body) }
            catch { throw StudioError.invalidResponse }
        } catch let error as StudioError { throw error }
        catch is CancellationError { throw CancellationError() }
        catch { if Task.isCancelled { throw CancellationError() }; throw StudioError.offline }
    }
    static func apiDecoder() -> JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .custom { value in
            let text = try value.singleValueContainer().decode(String.self)
            let formatter = ISO8601DateFormatter()
            formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
            if let date = formatter.date(from: text) { return date }
            formatter.formatOptions = [.withInternetDateTime]
            guard let date = formatter.date(from: text) else { throw StudioError.invalidResponse }
            return date
        }
        return decoder
    }
}
