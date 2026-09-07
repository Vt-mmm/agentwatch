import AppKit
import Foundation
import Network
import AgentWatchCore

@MainActor
enum GoogleBrowserAuthorization {
    static func authorize(configuration: GoogleOAuthConfiguration, scopes: Set<String>, loginHint: String? = nil) async throws -> GoogleCredential {
        let receiver = OAuthLoopbackReceiver()
        return try await withTaskCancellationHandler {
            defer { receiver.cancel() }
            try Task.checkCancellation()
            let redirect = try await receiver.start()
            try Task.checkCancellation()
            let attempt = try GoogleOAuthAttempt(redirectURI: redirect, scopes: scopes)
            guard NSWorkspace.shared.open(try attempt.authorizationURL(configuration: configuration, loginHint: loginHint)) else { throw GoogleServiceError.invalidConfiguration }
            let callback = try await receiver.callback()
            let code = try attempt.authorizationCode(callback: callback)
            return try await GoogleOAuthClient().exchange(code: code, attempt: attempt, configuration: configuration)
        } onCancel: { receiver.cancel() }
    }
    static func pickFolder(configuration: GoogleOAuthConfiguration, account: GoogleCredential) async throws -> DriveFolderAccess {
        let receiver = OAuthLoopbackReceiver()
        return try await withTaskCancellationHandler {
            defer { receiver.cancel() }
            let redirect = try await receiver.start()
            let attempt = try GoogleOAuthAttempt(redirectURI: redirect, scopes: [GoogleScopes.driveFile], folderPicker: true)
            guard NSWorkspace.shared.open(try attempt.authorizationURL(configuration: configuration, loginHint: account.email)) else { throw GoogleServiceError.invalidConfiguration }
            let callback = try await receiver.callback()
            let folderID = try attempt.pickedFolderID(callback: callback)
            let grant = try await GoogleOAuthClient().exchange(code: attempt.authorizationCode(callback: callback), attempt: attempt,
                configuration: configuration, pickerAccount: account)
            return try await DriveAPI().folder(folderID, credential: grant)
        } onCancel: { receiver.cancel() }
    }
}

/// Only the private queue accesses mutable state. Binds IPv4 loopback explicitly;
/// no network-wide listener, embedded browser, token logging or local auth-file read.
private final class OAuthLoopbackReceiver: @unchecked Sendable {
    private let queue = DispatchQueue(label: "agentwatch.google.loopback")
    private var listener: NWListener?
    private var startContinuation: CheckedContinuation<String, Error>?
    private var callbackContinuation: CheckedContinuation<URL, Error>?
    private var received: Result<URL, Error>?
    private var redirectURI: String?
    private var connections: [NWConnection] = []

    func start() async throws -> String {
        try await withCheckedThrowingContinuation { continuation in
            queue.async { [self] in
                startContinuation = continuation
                do {
                    let parameters = NWParameters.tcp
                    parameters.requiredLocalEndpoint = .hostPort(host: "127.0.0.1", port: .any)
                    let listener = try NWListener(using: parameters)
                    self.listener = listener
                    listener.stateUpdateHandler = { [weak self] state in
                        guard let self else { return }
                        switch state {
                        case .ready:
                            guard let port = listener.port else { self.fail(GoogleServiceError.invalidConfiguration); return }
                            let redirect = "http://127.0.0.1:\(port.rawValue)/oauth/callback"
                            self.redirectURI = redirect
                            self.startContinuation?.resume(returning: redirect); self.startContinuation = nil
                        case .failed: self.fail(GoogleServiceError.invalidConfiguration)
                        default: break
                        }
                    }
                    listener.newConnectionHandler = { [weak self] connection in
                        guard let self else { connection.cancel(); return }
                        guard self.connections.count < 8 else { connection.cancel(); return }
                        self.connections.append(connection); connection.start(queue: self.queue)
                        self.read(connection, buffer: Data())
                    }
                    listener.start(queue: queue)
                    queue.asyncAfter(deadline: .now() + 600) { [weak self] in self?.fail(GoogleServiceError.cancelled) }
                } catch { fail(GoogleServiceError.invalidConfiguration) }
            }
        }
    }
    func callback() async throws -> URL {
        try await withCheckedThrowingContinuation { continuation in
            queue.async { [self] in
                if let received { continuation.resume(with: received) }
                else { callbackContinuation = continuation }
            }
        }
    }
    func cancel() { queue.async { [self] in fail(GoogleServiceError.cancelled) } }
    private func read(_ connection: NWConnection, buffer: Data) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 4096) { [weak self] data, _, complete, error in
            guard let self else { connection.cancel(); return }
            var bytes = buffer; bytes.append(data ?? Data())
            guard bytes.count <= 16_384, error == nil else { connection.cancel(); return }
            guard let text = String(data: bytes, encoding: .utf8), text.contains("\r\n\r\n") else {
                if complete { connection.cancel() } else { self.read(connection, buffer: bytes) }
                return
            }
            let request = text.components(separatedBy: "\r\n").first?.split(separator: " ") ?? []
            guard request.count == 3, request[0] == "GET", let redirect = self.redirectURI,
                  let base = URLComponents(string: redirect), let port = base.port,
                  request[1].hasPrefix("/oauth/callback?") else {
                connection.cancel(); return
            }
            let target = String(request[1])
            guard let callback = URL(string: "http://127.0.0.1:\(port)" + target) else { connection.cancel(); return }
            let message = "AgentWatch đã nhận phản hồi đăng nhập. Quay lại ứng dụng để xem kết quả."
            let body = Data(message.utf8)
            var response = Data("HTTP/1.1 200 OK\r\nContent-Type: text/plain; charset=utf-8\r\nCache-Control: no-store\r\nConnection: close\r\nContent-Length: \(body.count)\r\n\r\n".utf8)
            response.append(body)
            connection.send(content: response, completion: .contentProcessed { _ in connection.cancel() })
            if self.received == nil {
                self.received = .success(callback)
                self.callbackContinuation?.resume(returning: callback); self.callbackContinuation = nil
                self.listener?.cancel()
            }
        }
    }
    private func fail(_ error: Error) {
        startContinuation?.resume(throwing: error); startContinuation = nil
        if received == nil { received = .failure(error) }
        callbackContinuation?.resume(with: received!); callbackContinuation = nil
        listener?.cancel(); listener = nil
        for connection in connections { connection.cancel() }; connections = []
    }
}
