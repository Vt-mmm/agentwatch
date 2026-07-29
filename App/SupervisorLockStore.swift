import AppKit
import CryptoKit
import Foundation
import Observation
import ClaudeWatchCore

struct SupervisorLockKey: Identifiable, Sendable, Equatable {
    let label: String
    let enrollmentHash: String
    let unlockPassHash: String
    var id: String { label }
}

enum SupervisorLockEventKind: String, Codable, Sendable, Equatable {
    case appStarted
    case cleanQuit
    case forceQuitSuspected
    case lockEnabled
    case lockDisabled
    case quitAuthorized
    case quitBlocked

    var label: String {
        switch self {
        case .appStarted:         return "App started"
        case .cleanQuit:          return "Clean quit"
        case .forceQuitSuspected: return "Force quit suspected"
        case .lockEnabled:        return "Lock enabled"
        case .lockDisabled:       return "Lock disabled"
        case .quitAuthorized:     return "Quit authorized"
        case .quitBlocked:        return "Quit blocked"
        }
    }

    var severity: String {
        switch self {
        case .forceQuitSuspected: return "critical"
        case .quitBlocked:        return "high"
        case .lockDisabled:       return "medium"
        default:                  return "info"
        }
    }
}

struct SupervisorLockAuditEvent: Identifiable, Codable, Sendable, Equatable {
    let id: UUID
    let timestamp: Date
    let kind: SupervisorLockEventKind
    let keyLabel: String?
    let message: String
    let downtimeSeconds: TimeInterval?
    let appVersion: String
}

@Observable
@MainActor
final class SupervisorLockStore {
    static let shared = SupervisorLockStore()

    static let keys: [SupervisorLockKey] = [
        .init(label: "Tài - BE", enrollmentHash: "6ff42c6e6263e081cf9bb1b94122e60ff0e0e51b593aa24018e9fcda91969e78", unlockPassHash: "4010a89e176c60586c541ef2423e50e1f8ca9e0b0cee8ca1cea2a526429d475f"),
        .init(label: "Dũng - BE", enrollmentHash: "1be030ee5bb367e40aedfc33785b396afad77ebc34384deeed48c0840638c518", unlockPassHash: "2871942179b7125f335c43bd8ad19d7b0d327a2baa19810e7625e1c30a1281a3"),
        .init(label: "Minh - BE", enrollmentHash: "e8f9d5d06e15b4c7c7d66bd5bc9137773953efd99a496decbaba7d1fc6f03f4e", unlockPassHash: "0419adae6bd2f48fba23248a4ce1d55099522a6a8740056b40899af041f43516"),
        .init(label: "Ngọc - BE", enrollmentHash: "b0ce7c7f927a8c8a00fecdb28aad9626f6d97240b0263f1fec789cc371b7e86c", unlockPassHash: "ce3e67502801aa9f51886a50711ae34f34f85d07afe2f24d73cbeff0a0b44d4f"),
        .init(label: "Bình - BE", enrollmentHash: "b710d1ca98b457196db400e5ca6b0d8cbaf7526ff1491a704cb0c4f0fadecad0", unlockPassHash: "fc97f2f20dcf017a931656f43ada0577c6ad5e9db1638d3b606e51e0de7298cb"),
        .init(label: "Đức - FE", enrollmentHash: "d2bc7383ea49d527f93a7440fc9c7cabe1286fdb98e4b6429d8234b067083895", unlockPassHash: "27a8aa2ff8aa882e74f4c5a8f509197358b026a1391222eb462b089a8fdf40b8"),
        .init(label: "Chiến - FE", enrollmentHash: "5f732d05e00e69b2d113041907c62fadb15740225ae8213608cd2ea04ebaab8e", unlockPassHash: "bab23d3e4d0e6c9ca109f936400f67c1f0605c0c3333d81b4c32f1f3bc453bab"),
        .init(label: "Mac1", enrollmentHash: "2c679ecf6acf2ee33090698668c9a05ef53b2c5338f5596c6ed870f67e2d89bf", unlockPassHash: "c4e6b11b9f2b0532004b6a4f084bda64fe5265d83838b9467fe60cf9121ace8c"),
        .init(label: "Mac2", enrollmentHash: "11af5c04015c9e651a3bd438bf9354056b317116cb61622ae2c7287983ae1e1a", unlockPassHash: "b9d7c91a98da34eacaa2db5a823d2479fa551aad155d7f2d67679c7ed32ba29f"),
        .init(label: "Mac3", enrollmentHash: "5331a527a0982d030131f89f42ecf9802cc4cd8e21fd8f1f0f2a0852ef5bacdc", unlockPassHash: "e4833fd75b9edc29d6b3388a4178d12404acd8d702fd238231b46a1efae04793"),
        .init(label: "Mac4", enrollmentHash: "62d6e1a881c89cd5c909622541f419da4b7a22b371518f65fd084761a2928080", unlockPassHash: "de0ce006288cb42456eafa0b1d1f428dfc016d309e75285524a8cd05cfa513b0"),
        .init(label: "Mac5", enrollmentHash: "4e6dd66953ecc86aeb3c5e5e147ca43f35e771dffde4b3b4872a1a03ceb40187", unlockPassHash: "92722d2c13e5ceb29b9dfde18439e8c15bfdd142aba38e5ae9158204cd2029ff"),
        .init(label: "Mac6", enrollmentHash: "24d3c0eb16190176d7e8135de76ff0e2bd16aa8336b688f09e3dd579ca8267eb", unlockPassHash: "9e97f349569e42d5b314d6a8fa547b2cca4a4bce334d7922118555fad006726b"),
        .init(label: "Mac7", enrollmentHash: "020e98465cfc1d5dd3d68f64c734a8f10706501b9c431d0961fbf8d7d14c8f9d", unlockPassHash: "32b477ab14a047d336dde23d4354919297dbe51d3da5d4235bffba3a8b9be12f"),
        .init(label: "Mac8", enrollmentHash: "da4f4621410e304f29eadd3edec751fb81866c49ae802660f10ed89da2f4913e", unlockPassHash: "b0e3017ee933a611a5cf12bff1d70af8bd100fbe6c3f32a3bab8a7c583cb24c4"),
        .init(label: "Mac9", enrollmentHash: "cf80bd890c5cfe105f508d13a2c0d9ad92516e49229c321cf05456dd0199d696", unlockPassHash: "ca725bacfdd771f4e44f3acaa2f20a347afdcf0d7021eb8aad8633ac23d4e4e1"),
        .init(label: "Mac10", enrollmentHash: "8fe5f1172cd54cf91fb8ca65d2df1f60b91500df5478afd9e9dc6a0b31a", unlockPassHash: "98d6d8863b2fb32d95853aa0131d5e0ae009e92e7ef95f414e94ecfe0fb32ce6"),
        .init(label: "Mac11", enrollmentHash: "7d075d785bf5c27e6af979120718465947b10b0700e3d8c8cdf8779b190454d0", unlockPassHash: "73bb923079ecf50dec0875b0342497daeac52bc9bc184d95550bb0f15ec2f9fc"),
        .init(label: "Mac12", enrollmentHash: "9abd3239cd2d8f5efdc64624111d8a4ee6b45ab2a47944c7242bf3e9e42c27c7", unlockPassHash: "e1679fa8133fbcc224a219f59e1e6339d02380291340bc1d1dd0fb6ca0ec521a"),
        .init(label: "Mac13", enrollmentHash: "0b1d64a9380409442bad07dc527ff6b9719178bbf50815a933afd1c82fd46dea", unlockPassHash: "4ef064d3ec2bd1782e9a1aa8ca3c0fb823472541e706ed5855b4c6adc054db72")
    ]

    private struct HeartbeatState: Codable {
        let runId: UUID
        let startedAt: Date
        let heartbeatAt: Date
        let cleanExit: Bool
        let locked: Bool
        let lockedByLabel: String?
        let pid: Int32
        let appVersion: String
    }

    private let lockedKey = "supervisor.lock.enabled"
    private let lockedByLabelKey = "supervisor.lock.byLabel"
    private let heartbeatInterval: TimeInterval = 60
    private let runId = UUID()
    private let runStartedAt = Date()

    private var started = false
    private var heartbeatTimer: Timer?
    private var terminationAuthorized = false
    private var didMarkCleanExit = false

    var isLocked: Bool
    var lockedByLabel: String?
    var lastHeartbeatAt: Date?
    var recentEvents: [SupervisorLockAuditEvent] = []

    private init() {
        isLocked = UserDefaults.standard.bool(forKey: lockedKey)
        lockedByLabel = UserDefaults.standard.string(forKey: lockedByLabelKey)
    }

    var statusLine: String {
        if isLocked {
            return "Locked" + (lockedByLabel.map { " · \($0)" } ?? "")
        }
        return "Enrollment required"
    }

    func start() {
        guard !started else { return }
        started = true
        recentEvents = loadAuditEvents(limit: 200)
        detectPreviousAbnormalShutdown()
        appendAudit(kind: .appStarted, keyLabel: nil, message: "Agent Watch opened.")
        writeHeartbeat(cleanExit: false)
        heartbeatTimer = Timer.scheduledTimer(withTimeInterval: heartbeatInterval, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.writeHeartbeat(cleanExit: false) }
        }
    }

    func enableLock(with rawKey: String) -> Bool {
        guard !isLocked, let key = matchEnrollmentKey(rawKey) else { return false }
        isLocked = true
        lockedByLabel = key.label
        persistLockState()
        appendAudit(kind: .lockEnabled, keyLabel: key.label,
                    message: "Supervisor lock enabled by \(key.label).")
        writeHeartbeat(cleanExit: false)
        return true
    }

    func disableLock(withUnlockPass rawPass: String) -> Bool {
        guard let key = matchUnlockPass(rawPass) else { return false }
        isLocked = false
        lockedByLabel = nil
        persistLockState()
        appendAudit(kind: .lockDisabled, keyLabel: key.label,
                    message: "Supervisor lock disabled by \(key.label) unlock pass.")
        writeHeartbeat(cleanExit: false)
        return true
    }

    func authorizeQuit(withUnlockPass rawPass: String, source: String) -> Bool {
        guard let key = matchUnlockPass(rawPass) else {
            appendAudit(kind: .quitBlocked, keyLabel: nil,
                        message: "Quit blocked from \(source): invalid unlock pass.")
            writeHeartbeat(cleanExit: false)
            return false
        }
        terminationAuthorized = true
        appendAudit(kind: .quitAuthorized, keyLabel: key.label,
                    message: "Quit authorized from \(source) by \(key.label) unlock pass.")
        markCleanExit(source: source)
        NSApp.terminate(nil)
        return true
    }

    func requestQuit(source: String = "ui") {
        NSApp.terminate(nil)
    }

    func shouldTerminate(source: String) -> NSApplication.TerminateReply {
        if terminationAuthorized {
            markCleanExit(source: source)
            return .terminateNow
        }

        if !isLocked {
            if let key = promptForEnrollmentKey(
                title: "Agent Watch cần được khóa",
                message: "Nhập enrollment key được cấp cho máy này để bật lock trước khi tiếp tục."
            ) {
                isLocked = true
                lockedByLabel = key.label
                persistLockState()
                appendAudit(kind: .lockEnabled, keyLabel: key.label,
                            message: "Quit from \(source) was blocked; supervisor lock enabled by \(key.label).")
                writeHeartbeat(cleanExit: false)
            } else {
                appendAudit(kind: .quitBlocked, keyLabel: nil,
                            message: "Quit blocked from \(source): app is not enrolled.")
                writeHeartbeat(cleanExit: false)
            }
            return .terminateCancel
        }

        if let key = promptForUnlockPass(
            title: "Agent Watch đang locked",
            message: "Nhập unlock pass để cho phép quit."
        ) {
            terminationAuthorized = true
            appendAudit(kind: .quitAuthorized, keyLabel: key.label,
                        message: "Quit authorized from \(source) by \(key.label) unlock pass.")
            markCleanExit(source: source)
            return .terminateNow
        }

        appendAudit(kind: .quitBlocked, keyLabel: nil,
                    message: "Quit blocked from \(source): missing or invalid unlock pass.")
        writeHeartbeat(cleanExit: false)
        return .terminateCancel
    }

    func markCleanExit(source: String) {
        guard !didMarkCleanExit else { return }
        didMarkCleanExit = true
        heartbeatTimer?.invalidate()
        heartbeatTimer = nil
        writeHeartbeat(cleanExit: true)
        appendAudit(kind: .cleanQuit, keyLabel: nil,
                    message: "Agent Watch quit cleanly from \(source).")
    }

    func events(in scope: ReportScope) -> [SupervisorLockAuditEvent] {
        let range = dateRange(for: scope)
        return loadAuditEvents(limit: nil)
            .filter { range.contains($0.timestamp) }
            .sorted { $0.timestamp > $1.timestamp }
    }

    func markdownSection(scope: ReportScope) -> String {
        let scoped = events(in: scope)
        var md = "\n## Agent Watch lock audit\n"
        if scoped.isEmpty {
            md += "_Không có lock/quit event trong khoảng này._\n"
            return md
        }
        md += "| Time | Event | Key | Downtime | Message |\n"
        md += "|---|---|---|---:|---|\n"
        for event in scoped.prefix(100) {
            let downtime = event.downtimeSeconds.map { humanDuration($0) } ?? ""
            md += "| \(Self.timestampFormatter.string(from: event.timestamp)) | \(event.kind.label) | \(event.keyLabel ?? "") | \(downtime) | \(event.message) |\n"
        }
        return md
    }

    func htmlSection(scope: ReportScope) -> String {
        let scoped = events(in: scope)
        guard !scoped.isEmpty else {
            return "<h2>Agent Watch lock audit</h2><p class=muted>Không có lock/quit event trong khoảng này.</p>"
        }
        let rows = scoped.prefix(100).map { event in
            let downtime = event.downtimeSeconds.map { humanDuration($0) } ?? ""
            return "<tr><td>\(htmlEscape(Self.timestampFormatter.string(from: event.timestamp)))</td>"
                + "<td>\(htmlEscape(event.kind.label))</td>"
                + "<td>\(htmlEscape(event.keyLabel ?? ""))</td>"
                + "<td>\(htmlEscape(downtime))</td>"
                + "<td>\(htmlEscape(event.message))</td></tr>"
        }.joined()
        return """
        <h2>Agent Watch lock audit</h2>
        <table><thead><tr><th>Time</th><th>Event</th><th>Key</th><th>Downtime</th><th>Message</th></tr></thead><tbody>\(rows)</tbody></table>
        """
    }

    func csvRows(scope: ReportScope) -> String {
        events(in: scope).map { event in
            let downtime = event.downtimeSeconds.map { humanDuration($0) } ?? ""
            let title = event.kind.label
            let recommendation: String
            switch event.kind {
            case .forceQuitSuspected:
                recommendation = "Check member activity around the last heartbeat and require explanation."
            case .quitBlocked:
                recommendation = "Review attempted quit; keep lock enabled."
            default:
                recommendation = ""
            }
            let cols: [String] = [
                "lock_audit",
                Self.timestampFormatter.string(from: event.timestamp),
                "agent_watch",
                "Agent Watch",
                event.id.uuidString,
                csvEscape(event.keyLabel ?? ""),
                "",
                "",
                "",
                "",
                "",
                "",
                "",
                "",
                "",
                "",
                "",
                "",
                event.kind == .forceQuitSuspected ? "100" : "",
                event.kind.severity,
                event.kind.rawValue,
                csvEscape(title),
                csvEscape(event.message),
                csvEscape(recommendation),
                "",
                "",
                "",
                "",
                "",
                csvEscape(downtime.isEmpty ? event.message : "\(event.message) Downtime: \(downtime)")
            ]
            return cols.joined(separator: ",")
        }.joined(separator: "\n")
    }

    private func matchEnrollmentKey(_ rawKey: String) -> SupervisorLockKey? {
        let hash = Self.hash(normalized(rawKey))
        return Self.keys.first { $0.enrollmentHash == hash }
    }

    private func matchUnlockPass(_ rawPass: String) -> SupervisorLockKey? {
        let hash = Self.hash(normalized(rawPass))
        guard let key = Self.keys.first(where: { $0.unlockPassHash == hash }) else {
            return nil
        }
        guard isLocked, let lockedByLabel else {
            return key
        }
        return key.label == lockedByLabel ? key : nil
    }

    private func normalized(_ rawKey: String) -> String {
        rawKey
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .uppercased()
    }

    private static func hash(_ value: String) -> String {
        let digest = SHA256.hash(data: Data(value.utf8))
        return digest.map { String(format: "%02x", $0) }.joined()
    }

    private func persistLockState() {
        let defaults = UserDefaults.standard
        defaults.set(isLocked, forKey: lockedKey)
        defaults.set(lockedByLabel, forKey: lockedByLabelKey)
    }

    private func detectPreviousAbnormalShutdown() {
        guard let previous = readHeartbeat(),
              !previous.cleanExit else {
            return
        }
        let downtime = max(0, Date().timeIntervalSince(previous.heartbeatAt))
        appendAudit(
            kind: .forceQuitSuspected,
            keyLabel: previous.lockedByLabel,
            message: "Previous app run stopped without clean quit. Last heartbeat at \(Self.timestampFormatter.string(from: previous.heartbeatAt)); recovered now.",
            downtimeSeconds: downtime
        )
    }

    private func writeHeartbeat(cleanExit: Bool) {
        let state = HeartbeatState(
            runId: runId,
            startedAt: runStartedAt,
            heartbeatAt: Date(),
            cleanExit: cleanExit,
            locked: isLocked,
            lockedByLabel: lockedByLabel,
            pid: ProcessInfo.processInfo.processIdentifier,
            appVersion: currentVersion
        )
        lastHeartbeatAt = state.heartbeatAt
        do {
            try FileManager.default.createDirectory(
                at: supportDirectory,
                withIntermediateDirectories: true,
                attributes: nil
            )
            let encoder = JSONEncoder()
            encoder.dateEncodingStrategy = .iso8601
            let data = try encoder.encode(state)
            try data.write(to: heartbeatURL, options: [.atomic])
        } catch {
            NSLog("Agent Watch heartbeat write failed: \(error)")
        }
    }

    private func readHeartbeat() -> HeartbeatState? {
        guard let data = try? Data(contentsOf: heartbeatURL) else { return nil }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try? decoder.decode(HeartbeatState.self, from: data)
    }

    private func appendAudit(kind: SupervisorLockEventKind,
                             keyLabel: String?,
                             message: String,
                             downtimeSeconds: TimeInterval? = nil) {
        let event = SupervisorLockAuditEvent(
            id: UUID(),
            timestamp: Date(),
            kind: kind,
            keyLabel: keyLabel,
            message: message,
            downtimeSeconds: downtimeSeconds,
            appVersion: currentVersion
        )
        do {
            try FileManager.default.createDirectory(
                at: supportDirectory,
                withIntermediateDirectories: true,
                attributes: nil
            )
            let encoder = JSONEncoder()
            encoder.dateEncodingStrategy = .iso8601
            var data = try encoder.encode(event)
            data.append(0x0A)
            if FileManager.default.fileExists(atPath: auditURL.path) {
                let handle = try FileHandle(forWritingTo: auditURL)
                try handle.seekToEnd()
                try handle.write(contentsOf: data)
                try handle.close()
            } else {
                try data.write(to: auditURL, options: [.atomic])
            }
            recentEvents.insert(event, at: 0)
            if recentEvents.count > 200 {
                recentEvents.removeLast(recentEvents.count - 200)
            }
        } catch {
            NSLog("Agent Watch lock audit write failed: \(error)")
        }
    }

    private func loadAuditEvents(limit: Int?) -> [SupervisorLockAuditEvent] {
        guard let raw = try? String(contentsOf: auditURL, encoding: .utf8) else { return [] }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let decoded = raw
            .split(separator: "\n")
            .compactMap { line -> SupervisorLockAuditEvent? in
                guard let data = String(line).data(using: .utf8) else { return nil }
                return try? decoder.decode(SupervisorLockAuditEvent.self, from: data)
            }
            .sorted { $0.timestamp > $1.timestamp }
        if let limit {
            return Array(decoded.prefix(limit))
        }
        return decoded
    }

    private func promptForEnrollmentKey(title: String, message: String) -> SupervisorLockKey? {
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = message
        alert.alertStyle = .warning
        alert.addButton(withTitle: "Lock")
        alert.addButton(withTitle: "Cancel")

        let field = NSSecureTextField(frame: NSRect(x: 0, y: 0, width: 280, height: 24))
        field.placeholderString = "AW-LOCK-XXXX-XXXX-XXXX"
        alert.accessoryView = field
        alert.window.initialFirstResponder = field

        guard alert.runModal() == .alertFirstButtonReturn,
              let key = matchEnrollmentKey(field.stringValue) else {
            return nil
        }
        return key
    }

    private func promptForUnlockPass(title: String, message: String) -> SupervisorLockKey? {
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = message
        alert.alertStyle = .warning
        alert.addButton(withTitle: "Unlock")
        alert.addButton(withTitle: "Cancel")

        let field = NSSecureTextField(frame: NSRect(x: 0, y: 0, width: 280, height: 24))
        field.placeholderString = "Unlock pass"
        alert.accessoryView = field
        alert.window.initialFirstResponder = field

        guard alert.runModal() == .alertFirstButtonReturn,
              let key = matchUnlockPass(field.stringValue) else {
            return nil
        }
        return key
    }

    private var supportDirectory: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? FileManager.default.homeDirectoryForCurrentUser
        return base.appendingPathComponent("Agent Watch", isDirectory: true)
    }

    private var heartbeatURL: URL {
        supportDirectory.appendingPathComponent("lock-heartbeat.json")
    }

    private var auditURL: URL {
        supportDirectory.appendingPathComponent("lock-audit.jsonl")
    }

    private var currentVersion: String {
        Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "dev"
    }

    private func dateRange(for scope: ReportScope) -> ClosedRange<Date> {
        let cal = Calendar.current
        switch scope {
        case .day(let date):
            let start = cal.startOfDay(for: date)
            let end = (cal.date(byAdding: .day, value: 1, to: start) ?? start)
                .addingTimeInterval(-1)
            return start...end
        case .week(let start):
            let begin = cal.startOfDay(for: start)
            let end = (cal.date(byAdding: .day, value: 7, to: begin) ?? begin)
                .addingTimeInterval(-1)
            return begin...end
        case .custom(let start, let end, _):
            return start...end
        }
    }

    private func humanDuration(_ seconds: TimeInterval) -> String {
        let mins = Int(seconds / 60)
        if mins < 1 { return "\(Int(seconds))s" }
        if mins < 60 { return "\(mins)m" }
        return "\(mins / 60)h \(mins % 60)m"
    }

    private func csvEscape(_ value: String) -> String {
        let needs = value.contains(",") || value.contains("\"") || value.contains("\n")
        if !needs { return value }
        return "\"" + value.replacingOccurrences(of: "\"", with: "\"\"") + "\""
    }

    private func htmlEscape(_ value: String) -> String {
        value
            .replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
    }

    nonisolated(unsafe) private static let timestampFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd HH:mm:ss"
        formatter.timeZone = .current
        return formatter
    }()
}

@MainActor
final class AgentWatchAppDelegate: NSObject, NSApplicationDelegate {
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        SupervisorLockStore.shared.shouldTerminate(source: "application")
    }

    func applicationWillTerminate(_ notification: Notification) {
        SupervisorLockStore.shared.markCleanExit(source: "applicationWillTerminate")
    }
}
