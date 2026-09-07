import Foundation

public struct GoogleHTTPResponse: Sendable {
    public let status: Int
    public let headers: [String: String]
    public let body: Data
    public init(status: Int, headers: [String: String] = [:], body: Data = Data()) {
        self.status = status; self.headers = headers; self.body = body
    }
}
public protocol GoogleHTTPTransport: Sendable {
    func send(_ request: URLRequest) async throws -> GoogleHTTPResponse
}

public enum GoogleServiceError: Error, LocalizedError, Sendable, Equatable {
    case invalidConfiguration, invalidCallback, cancelled, missingScope, wrongAccount
    case authenticationRequired, permissionDenied, rateLimited, notFound, conflict
    case rejected(Int), uncertain, invalidResponse, unsupportedSize, storage(String)
    public var errorDescription: String? {
        switch self {
        case .invalidConfiguration: "Kiểm tra OAuth client loại Desktop và cấu hình Google."
        case .invalidCallback: "Phản hồi đăng nhập không khớp phiên xác thực."
        case .cancelled: "Đã hủy đăng nhập Google."
        case .missingScope: "Tài khoản chưa cấp đủ quyền cho thao tác đã chọn."
        case .wrongAccount: "Tài khoản đang đăng nhập khác tài khoản được duyệt cho thao tác này."
        case .authenticationRequired: "Cần đăng nhập lại Google."
        case .permissionDenied: "Google từ chối quyền truy cập. Kiểm tra tài khoản và thư mục được chọn."
        case .rateLimited: "Google đang giới hạn lượt gọi. Thao tác cần thử lại sau."
        case .notFound: "Không tìm thấy hoặc không có quyền đọc đối tượng trên Google."
        case .conflict: "Mã đối tượng đã tồn tại; cần đối chiếu bản đã upload."
        case .rejected(let code): "Google từ chối yêu cầu (HTTP \(code))."
        case .uncertain: "Chưa xác định Google đã nhận yêu cầu hay chưa; cần đối chiếu trước khi thử lại."
        case .invalidResponse: "Phản hồi Google không đủ dữ liệu để xác nhận thao tác."
        case .unsupportedSize: "Report vượt giới hạn upload được hỗ trợ."
        case .storage(let message): message
        }
    }
    public static func from(status: Int) -> GoogleServiceError {
        switch status {
        case 401: .authenticationRequired
        case 403: .permissionDenied
        case 404: .notFound
        case 409: .conflict
        case 429: .rateLimited
        default: status >= 500 ? .uncertain : .rejected(status)
        }
    }
    public static func from(response: GoogleHTTPResponse) -> GoogleServiceError {
        if response.status == 403, let object = try? GoogleWire.json(response.body), let error = object["error"] as? [String: Any],
           let rows = error["errors"] as? [[String: Any]], rows.contains(where: {
               ["rateLimitExceeded", "userRateLimitExceeded", "dailyLimitExceeded"].contains($0["reason"] as? String ?? "")
           }) { return .rateLimited }
        return from(status: response.status)
    }
}

public struct GoogleRateLimitFailure: Error, LocalizedError, Sendable {
    public let retryAt: Date?
    public var errorDescription: String? { GoogleServiceError.rateLimited.localizedDescription }
    public init(response: GoogleHTTPResponse, now: Date = Date()) {
        let raw = response.headers.first { $0.key.lowercased() == "retry-after" }?.value
        if let raw, let seconds = Double(raw), seconds.isFinite, seconds >= 0, seconds <= 31_536_000 {
            retryAt = now.addingTimeInterval(seconds)
        } else if let raw {
            let formatter = DateFormatter(); formatter.locale = Locale(identifier: "en_US_POSIX"); formatter.timeZone = TimeZone(secondsFromGMT: 0)
            formatter.dateFormat = "EEE, dd MMM yyyy HH:mm:ss zzz"
            retryAt = formatter.date(from: raw)
        } else { retryAt = nil }
    }
}

/// Never follows redirects with credentials. The service layer constructs all
/// endpoint URLs; report content and model output cannot choose an API host.
public final class GoogleURLSessionTransport: NSObject, GoogleHTTPTransport, URLSessionTaskDelegate, @unchecked Sendable {
    public override init() { super.init() }
    public func send(_ request: URLRequest) async throws -> GoogleHTTPResponse {
        let allowedHosts: Set<String> = ["oauth2.googleapis.com", "openidconnect.googleapis.com", "www.googleapis.com", "gmail.googleapis.com"]
        guard let url = request.url, url.scheme == "https", let host = url.host, allowedHosts.contains(host),
              url.user == nil, url.password == nil else { throw GoogleServiceError.invalidConfiguration }
        let config = URLSessionConfiguration.ephemeral
        config.httpCookieStorage = nil; config.urlCache = nil
        config.timeoutIntervalForRequest = 30; config.timeoutIntervalForResource = 90
        let session = URLSession(configuration: config, delegate: self, delegateQueue: nil)
        defer { session.invalidateAndCancel() }
        let (body, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else { throw GoogleServiceError.invalidResponse }
        var headers: [String: String] = [:]
        for (key, value) in http.allHeaderFields { headers[String(describing: key).lowercased()] = String(describing: value) }
        return GoogleHTTPResponse(status: http.statusCode, headers: headers, body: body)
    }
    public func urlSession(_ session: URLSession, task: URLSessionTask,
                           willPerformHTTPRedirection response: HTTPURLResponse, newRequest request: URLRequest,
                           completionHandler: @escaping (URLRequest?) -> Void) { completionHandler(nil) }
}

public enum GoogleWire {
    public static func form(_ fields: [String: String]) -> Data {
        let safe = CharacterSet(charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-._~")
        return Data(fields.keys.sorted().map { key in
            "\(key.addingPercentEncoding(withAllowedCharacters: safe)!)=\(fields[key]!.addingPercentEncoding(withAllowedCharacters: safe)!)"
        }.joined(separator: "&").utf8)
    }
    public static func json(_ body: Data) throws -> [String: Any] {
        guard let object = try JSONSerialization.jsonObject(with: body) as? [String: Any] else { throw GoogleServiceError.invalidResponse }
        return object
    }
    public static func request(url: URL, method: String = "GET", token: String? = nil, body: Data? = nil, contentType: String? = nil) -> URLRequest {
        var request = URLRequest(url: url); request.httpMethod = method; request.httpBody = body
        if let token { request.setValue("Bearer " + token, forHTTPHeaderField: "Authorization") }
        if let contentType { request.setValue(contentType, forHTTPHeaderField: "Content-Type") }
        return request
    }
}
