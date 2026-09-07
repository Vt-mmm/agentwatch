import Foundation
import Darwin

/// Small read-only app-server exchange; no login, turn, command or model call.
/// Kept separate from the process transport so protocol failures are testable.
struct CodexQuotaExchange {
    var result: QuotaSnapshot?
    private var initialized = false

    static var initialize: [String: Any] {
        ["id": 1, "method": "initialize", "params": [
            "clientInfo": ["name": "agentwatch_quota", "version": "1.0.0"]]]
    }

    mutating func receive(_ message: [String: Any], at now: Date = Date()) -> [[String: Any]] {
        guard result == nil, let id = message["id"] as? Int else { return [] }
        if let error = message["error"] as? [String: Any] {
            let unsupported = error["code"] as? Int == -32601
            result = .unavailable(provider: "openai", source: "codex-app-server", at: now,
                                  reason: unsupported ? "Installed Codex does not expose this quota method. Update Codex or use an approved provider adapter."
                                    : "Codex could not read account quota. Check CLI sign-in and connection; no auth file was read by AgentWatch.",
                                  state: unsupported ? .unsupported : .failed)
            return []
        }
        guard let payload = message["result"] as? [String: Any] else { return [] }
        if id == 1, !initialized {
            initialized = true
            return [["method": "initialized"], ["id": 2, "method": "account/rateLimits/read", "params": [:]]]
        }
        if id == 2, initialized { result = QuotaParser.codex(payload, at: now) }
        return []
    }
}

public enum CodexQuotaClient {
    /// GUI launches do not inherit the user's interactive shell PATH.
    public static var installedCandidates: [URL] {
        ["/Applications/ChatGPT.app/Contents/Resources/codex",
         "/Applications/Codex.app/Contents/Resources/codex",
         NSHomeDirectory() + "/Applications/ChatGPT.app/Contents/Resources/codex",
         NSHomeDirectory() + "/Applications/Codex.app/Contents/Resources/codex",
         "/opt/homebrew/bin/codex", "/usr/local/bin/codex"].map { URL(fileURLWithPath: $0) }
    }
    public static func installedExecutable(candidates: [URL] = installedCandidates) -> URL? {
        candidates.first { $0.isFileURL && FileManager.default.isExecutableFile(atPath: $0.path) &&
            (try? $0.resolvingSymlinksInPath().resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true }
    }

    /// Call only after the operator explicitly requests refresh. The selected
    /// executable runs in a neutral directory, never a project checkout.
    public static func read(executable: URL, timeout: TimeInterval = 12) -> QuotaSnapshot {
        guard executable.isFileURL, FileManager.default.isExecutableFile(atPath: executable.path) else {
            return .unavailable(provider: "openai", source: "codex-app-server", reason: "Select the installed Codex CLI executable.", state: .unsupported)
        }
        let process = Process()
        let stdin = Pipe(), stdout = Pipe()
        process.executableURL = executable
        process.arguments = ["app-server"]
        var environment = ProcessInfo.processInfo.environment
        environment["PATH"] = [executable.deletingLastPathComponent().path, "/opt/homebrew/bin", "/usr/local/bin", environment["PATH"] ?? "/usr/bin:/bin"].joined(separator: ":")
        process.environment = environment
        process.currentDirectoryURL = FileManager.default.temporaryDirectory
        process.standardInput = stdin
        process.standardOutput = stdout
        process.standardError = FileHandle.nullDevice
        let state = ExchangeState(writer: stdin.fileHandleForWriting)
        stdout.fileHandleForReading.readabilityHandler = { handle in
            state.consume(handle.availableData)
        }
        do {
            try process.run()
            try state.start()
        } catch {
            state.fail("Unable to start the selected Codex CLI.")
        }
        if state.finished.wait(timeout: .now() + max(1, min(timeout, 30))) == .timedOut {
            state.fail("Codex quota request timed out; existing snapshots remain historical.")
        }
        let result = state.finish()
        stdout.fileHandleForReading.readabilityHandler = nil
        try? stdin.fileHandleForWriting.close()
        if process.isRunning {
            process.terminate()
            // Only this child process is owned by the adapter. Bound cleanup
            // even when a broken CLI ignores termination.
            if process.isRunning { kill(process.processIdentifier, SIGKILL) }
        }
        try? stdout.fileHandleForReading.close()
        return result
    }
}

/// All mutable state and pipe writes are protected by lock. The semaphore only
/// wakes the caller; it never owns protocol state.
private final class ExchangeState: @unchecked Sendable {
    let finished = DispatchSemaphore(value: 0)
    private let lock = NSLock()
    private var exchange = CodexQuotaExchange()
    private var buffer = Data()
    private var closed = false
    private let writer: FileHandle
    init(writer: FileHandle) { self.writer = writer }

    func start() throws {
        try lock.withLock { try send(CodexQuotaExchange.initialize) }
    }
    func consume(_ data: Data) {
        lock.withLock {
            guard !closed else { return }
            guard !data.isEmpty else { failLocked("Codex closed its quota connection before returning data."); return }
            buffer.append(data)
            guard buffer.count <= 2_000_000 else { failLocked("Codex quota response exceeded the supported size."); return }
            while let index = buffer.firstIndex(of: 10) {
                let line = Data(buffer[..<index]); buffer.removeSubrange(...index)
                guard let message = (try? JSONSerialization.jsonObject(with: line)) as? [String: Any] else { continue }
                do { for request in exchange.receive(message) { try send(request) } }
                catch { failLocked("Unable to request Codex quota."); return }
                if exchange.result != nil { closed = true; finished.signal(); return }
            }
        }
    }
    func fail(_ reason: String) { lock.withLock { failLocked(reason) } }
    private func failLocked(_ reason: String) {
        guard !closed else { return }
        closed = true
        exchange.result = .unavailable(provider: "openai", source: "codex-app-server", reason: reason, state: .failed)
        finished.signal()
    }
    func finish() -> QuotaSnapshot {
        lock.withLock {
            closed = true
            return exchange.result ?? .unavailable(provider: "openai", source: "codex-app-server", reason: "No quota response.")
        }
    }
    private func send(_ request: [String: Any]) throws {
        var data = try JSONSerialization.data(withJSONObject: request)
        data.append(10)
        try writer.write(contentsOf: data)
    }
}
