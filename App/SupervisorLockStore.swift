import AppKit
import CryptoKit
import Foundation
import Observation
import ServiceManagement
import ClaudeWatchCore

struct SupervisorLockKey: Identifiable, Sendable, Equatable {
    let label: String
    let enrollmentHash: String
    let unlockPassHash: String
    var id: String { label }
}

enum SupervisorLockEventKind: String, Codable, Sendable, Equatable {
    case appStarted
    case appOpenVerified
    case appOpenKeyRejected
    case cleanQuit
    case forceQuitSuspected
    case lockEnabled
    case lockDisabled
    case quitAuthorized
    case quitBlocked
    case systemWillSleep
    case systemDidWake
    case systemWillPowerOff
    case launchAtLoginEnabled
    case launchAtLoginNeedsApproval
    case launchAtLoginFailed
    case logReadStarted
    case logReadCompleted
    case reportExported
    case reportExportFailed
    case reportExportCancelled

    var label: String {
        switch self {
        case .appStarted:         return "App started"
        case .appOpenVerified:    return "App open verified"
        case .appOpenKeyRejected: return "Open key rejected"
        case .cleanQuit:          return "Clean quit"
        case .forceQuitSuspected: return "Force quit suspected"
        case .lockEnabled:        return "Lock enabled"
        case .lockDisabled:       return "Lock disabled"
        case .quitAuthorized:     return "Quit authorized"
        case .quitBlocked:        return "Quit blocked"
        case .systemWillSleep:    return "System sleep"
        case .systemDidWake:      return "System wake"
        case .systemWillPowerOff: return "System power off"
        case .launchAtLoginEnabled:
            return "Launch at login enabled"
        case .launchAtLoginNeedsApproval:
            return "Launch at login needs approval"
        case .launchAtLoginFailed:
            return "Launch at login failed"
        case .logReadStarted:      return "Log read started"
        case .logReadCompleted:    return "Log read completed"
        case .reportExported:      return "Report exported"
        case .reportExportFailed:  return "Report export failed"
        case .reportExportCancelled:
            return "Report export cancelled"
        }
    }

    var severity: String {
        switch self {
        case .forceQuitSuspected: return "critical"
        case .appOpenKeyRejected: return "high"
        case .quitBlocked:        return "high"
        case .lockDisabled:       return "medium"
        case .launchAtLoginNeedsApproval:
            return "medium"
        case .launchAtLoginFailed:
            return "high"
        case .reportExportFailed:
            return "high"
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

struct AgentWatchPresenceSample: Identifiable, Codable, Sendable, Equatable {
    let id: UUID
    let runId: UUID
    let timestamp: Date
    let locked: Bool
    let keyLabel: String?
    let startupVerified: Bool
    let appVersion: String
}

struct WorkComplianceFinding: Identifiable, Sendable, Equatable {
    let id: UUID
    let timestamp: Date
    let severity: String
    let title: String
    let message: String
    let recommendation: String
    let source: SessionSource?
    let sessionId: String?
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
        let startupVerified: Bool?
        let startupVerifiedAt: Date?
        let pid: Int32
        let appVersion: String
    }

    private let lockedKey = "supervisor.lock.enabled"
    private let lockedByLabelKey = "supervisor.lock.byLabel"
    private let heartbeatInterval: TimeInterval = 60
    private let updateRelaunchAuthorizationWindow: TimeInterval = 5
    private let runId = UUID()
    private let runStartedAt = Date()

    private var started = false
    private var heartbeatTimer: Timer?
    private var updateRelaunchAuthorizedUntil: Date?
    private var powerObserverTokens: [NSObjectProtocol] = []
    private var terminationAuthorized = false
    private var didMarkCleanExit = false

    var isLocked: Bool
    var lockedByLabel: String?
    var startupVerified: Bool = false
    var startupVerifiedAt: Date?
    var lastHeartbeatAt: Date?
    var recentEvents: [SupervisorLockAuditEvent] = []

    private init() {
        isLocked = UserDefaults.standard.bool(forKey: lockedKey)
        lockedByLabel = UserDefaults.standard.string(forKey: lockedByLabelKey)
    }

    var statusLine: String {
        if requiresStartupKey {
            return "Open key required" + (lockedByLabel.map { " · \($0)" } ?? "")
        }
        if isLocked {
            return "Locked" + (lockedByLabel.map { " · \($0)" } ?? "")
        }
        return "Enrollment required"
    }

    var requiresStartupKey: Bool {
        !startupVerified
    }

    func start() {
        guard !started else { return }
        started = true
        recentEvents = loadAuditEvents(limit: 200)
        detectPreviousAbnormalShutdown()
        appendAudit(kind: .appStarted, keyLabel: lockedByLabel,
                    message: "Agent Watch opened; enrollment key is required to record this app-open.")
        ensureLaunchAtLogin()
        writeHeartbeat(cleanExit: false)
        installPowerObservers()
        heartbeatTimer = Timer.scheduledTimer(withTimeInterval: heartbeatInterval, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.writeHeartbeat(cleanExit: false) }
        }
    }

    func verifyAppOpen(with rawKey: String) -> Bool {
        guard let key = matchEnrollmentKey(rawKey),
              lockedByLabel == nil || lockedByLabel == key.label else {
            appendAudit(kind: .appOpenKeyRejected, keyLabel: lockedByLabel,
                        message: "App-open enrollment key was rejected.")
            writeHeartbeat(cleanExit: false)
            return false
        }
        applyVerifiedAppOpen(key: key)
        return true
    }

    func enableLock(with rawKey: String) -> Bool {
        if requiresStartupKey {
            return verifyAppOpen(with: rawKey)
        }
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

    /// Sparkle invokes this immediately before its verified update relaunch.
    /// The one-shot window prevents a stale authorization from weakening
    /// ordinary Quit/Cmd+Q behavior if installation is unexpectedly aborted.
    func authorizeUpdateRelaunch() {
        updateRelaunchAuthorizedUntil = Date()
            .addingTimeInterval(updateRelaunchAuthorizationWindow)
        appendAudit(
            kind: .quitAuthorized,
            keyLabel: lockedByLabel,
            message: "Quit authorized automatically for verified Sparkle update relaunch; unlock pass was not requested."
        )
    }

    func shouldTerminate(source: String) -> NSApplication.TerminateReply {
        if let authorizedUntil = updateRelaunchAuthorizedUntil {
            updateRelaunchAuthorizedUntil = nil
            if Date() <= authorizedUntil {
                markCleanExit(source: "Sparkle update relaunch")
                return .terminateNow
            }
        }

        if terminationAuthorized {
            markCleanExit(source: source)
            return .terminateNow
        }

        if requiresStartupKey {
            if let key = promptForEnrollmentKey(
                title: "Agent Watch cần ghi nhận mở app",
                message: "Nhập enrollment key của máy này để ghi log mở app trước khi tiếp tục."
            ) {
                if lockedByLabel == nil || lockedByLabel == key.label {
                    applyVerifiedAppOpen(key: key)
                } else {
                    appendAudit(kind: .appOpenKeyRejected, keyLabel: lockedByLabel,
                                message: "Quit blocked from \(source): enrollment key belongs to \(key.label), not this enrolled machine.")
                    writeHeartbeat(cleanExit: false)
                }
            } else {
                appendAudit(kind: .quitBlocked, keyLabel: lockedByLabel,
                            message: "Quit blocked from \(source): app-open key has not been verified.")
                writeHeartbeat(cleanExit: false)
            }
            return .terminateCancel
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
        removePowerObservers()
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

    func recordScanStarted(reason: String, scope: ReportScope) {
        appendAudit(
            kind: .logReadStarted,
            keyLabel: lockedByLabel,
            message: "reason=\(reason); scope=\(scope.label); timezone=GMT+7"
        )
    }

    func recordScanCompleted(_ audit: CoachingScanAudit) {
        let duration = max(0, audit.finishedAt.timeIntervalSince(audit.startedAt))
        let sources = audit.sourceSessionCounts
            .sorted { $0.key < $1.key }
            .map { "\($0.key):\($0.value)" }
            .joined(separator: "|")
        appendAudit(
            kind: .logReadCompleted,
            keyLabel: lockedByLabel,
            message: "accounting=\(CoachingScanAudit.accountingVersion); pricing=\(Pricing.versionLabel); reason=\(audit.reason); scope=\(audit.scope.label); files=\(audit.candidateFileCount); sources=\(sources); sessions=\(audit.sessionCount); prompts=\(audit.promptCount); tokens=\(audit.totalTokens); reported_cost=\(String(format: "%.6f", audit.reportedCost)); estimated_cost=\(String(format: "%.6f", audit.estimatedCost)); unavailable_cost_sessions=\(audit.unavailableCostSessions); partial_range_sessions=\(audit.partialRangeSessions); data_warnings=\(audit.dataWarningCount); duration_ms=\(Int(duration * 1_000))"
        )
    }

    func recordReportExport(format: String, scope: ReportScope, url: URL) {
        appendAudit(
            kind: .reportExported,
            keyLabel: lockedByLabel,
            message: "format=\(format); scope=\(scope.label); path=\(url.path)"
        )
    }

    func recordReportExportFailure(format: String, scope: ReportScope, error: Error) {
        appendAudit(
            kind: .reportExportFailed,
            keyLabel: lockedByLabel,
            message: "format=\(format); scope=\(scope.label); error=\(error.localizedDescription)"
        )
    }

    func recordReportExportCancelled(format: String, scope: ReportScope) {
        appendAudit(
            kind: .reportExportCancelled,
            keyLabel: lockedByLabel,
            message: "format=\(format); scope=\(scope.label)"
        )
    }

    func complianceFindings(scope: ReportScope,
                            sessions: [SessionSummary]) -> [WorkComplianceFinding] {
        let range = dateRange(for: scope)
        let samples = loadPresenceSamples(in: range)
        let verifiedSamples = samples.filter(\.startupVerified)
        var findings: [WorkComplianceFinding] = []

        if !sessions.isEmpty && verifiedSamples.isEmpty {
            findings.append(WorkComplianceFinding(
                id: UUID(),
                timestamp: range.lowerBound,
                severity: "critical",
                title: "No verified Agent Watch open",
                message: "Có agent sessions trong kỳ nhưng không có heartbeat nào sau khi nhập enrollment key.",
                recommendation: "Yêu cầu member mở Agent Watch và nhập key trước khi bắt đầu task.",
                source: nil,
                sessionId: nil
            ))
        }

        let firstVerifiedAt = verifiedSamples
            .map(\.timestamp)
            .min()

        for session in sessions where session.promptCount > 0 || session.totalTokens > 0 {
            let first = session.firstTimestamp ?? session.lastTimestamp
            let last = session.lastTimestamp ?? session.firstTimestamp
            guard let first, let last else { continue }
            let lower = first.addingTimeInterval(-heartbeatInterval * 2)
            let upper = last.addingTimeInterval(heartbeatInterval * 2)
            let covered = verifiedSamples.contains { sample in
                sample.timestamp >= lower && sample.timestamp <= upper
            }
            if !covered {
                let title: String
                let message: String
                let recommendation: String
                if let firstVerifiedAt,
                   firstVerifiedAt > upper {
                    title = "Session finished before Agent Watch opened"
                    message = "\(session.source.label) session '\(session.displayTitle)' đã chạy xong trước khi Agent Watch được mở và nhập key."
                    recommendation = "Đánh dấu vi phạm flow: member phải mở Agent Watch, nhập key, rồi mới bắt đầu agent task."
                } else {
                    title = "Agent session outside app coverage"
                    message = "\(session.source.label) session '\(session.displayTitle)' không có verified Agent Watch heartbeat trong lúc chạy."
                    recommendation = "Đối chiếu audit log và yêu cầu member giải trình nếu task được làm khi app chưa mở hoặc chưa nhập key."
                }
                findings.append(WorkComplianceFinding(
                    id: UUID(),
                    timestamp: first,
                    severity: session.source.vendor == .piagent ? "critical" : "high",
                    title: title,
                    message: message,
                    recommendation: recommendation,
                    source: session.source,
                    sessionId: session.id
                ))
            }
        }

        return findings.sorted {
            if $0.severity != $1.severity { return $0.severity < $1.severity }
            return $0.timestamp > $1.timestamp
        }
    }

    func markdownSection(scope: ReportScope) -> String {
        let scoped = events(in: scope)
        var md = "\n## Agent Watch activity audit\n"
        if scoped.isEmpty {
            md += "_Không có app activity event trong khoảng này._\n"
            return md
        }
        md += "| Time | Event | Key | Downtime | Message |\n"
        md += "|---|---|---|---:|---|\n"
        for event in scoped {
            let downtime = event.downtimeSeconds.map { humanDuration($0) } ?? ""
            md += "| \(Self.timestampFormatter.string(from: event.timestamp)) | \(event.kind.label) | \(event.keyLabel ?? "") | \(downtime) | \(event.message) |\n"
        }
        return md
    }

    func complianceMarkdownSection(scope: ReportScope,
                                   sessions: [SessionSummary]) -> String {
        let findings = complianceFindings(scope: scope, sessions: sessions)
        var md = "\n## Agent Watch compliance\n"
        if findings.isEmpty {
            md += "_Không có coverage violation trong kỳ này._\n"
            return md
        }
        md += "| Severity | Time | Source | Session | Finding | Recommendation |\n"
        md += "|---|---|---|---|---|---|\n"
        for finding in findings {
            md += "| \(finding.severity) | \(Self.timestampFormatter.string(from: finding.timestamp)) | \(finding.source?.label ?? "Agent Watch") | \(finding.sessionId ?? "") | \(finding.message) | \(finding.recommendation) |\n"
        }
        return md
    }

    func htmlSection(scope: ReportScope) -> String {
        let scoped = events(in: scope)
        guard !scoped.isEmpty else {
            return "<h2>Agent Watch activity audit</h2><p class=muted>Không có app activity event trong khoảng này.</p>"
        }
        let rows = scoped.map { event in
            let downtime = event.downtimeSeconds.map { humanDuration($0) } ?? ""
            return "<tr><td>\(htmlEscape(Self.timestampFormatter.string(from: event.timestamp)))</td>"
                + "<td>\(htmlEscape(event.kind.label))</td>"
                + "<td>\(htmlEscape(event.keyLabel ?? ""))</td>"
                + "<td>\(htmlEscape(downtime))</td>"
                + "<td>\(htmlEscape(event.message))</td></tr>"
        }.joined()
        return """
        <h2>Agent Watch activity audit</h2>
        <div class="table-scroll"><table class="wide-table"><thead><tr><th>Time (GMT+7)</th><th>Event</th><th>Key</th><th>Downtime</th><th>Message</th></tr></thead><tbody>\(rows)</tbody></table></div>
        """
    }

    func complianceHTMLSection(scope: ReportScope,
                               sessions: [SessionSummary]) -> String {
        let findings = complianceFindings(scope: scope, sessions: sessions)
        guard !findings.isEmpty else {
            return "<h2>Agent Watch compliance</h2><p class=muted>Không có coverage violation trong kỳ này.</p>"
        }
        let rows = findings.map { finding in
            "<tr><td>\(htmlEscape(finding.severity))</td>"
                + "<td>\(htmlEscape(Self.timestampFormatter.string(from: finding.timestamp)))</td>"
                + "<td>\(htmlEscape(finding.source?.label ?? "Agent Watch"))</td>"
                + "<td>\(htmlEscape(finding.sessionId ?? ""))</td>"
                + "<td>\(htmlEscape(finding.message))</td>"
                + "<td>\(htmlEscape(finding.recommendation))</td></tr>"
        }.joined()
        return """
        <h2>Agent Watch compliance</h2>
        <div class="table-scroll"><table class="wide-table risk-table"><thead><tr><th>Severity</th><th>Time (GMT+7)</th><th>Source</th><th>Session</th><th>Finding</th><th>Recommendation</th></tr></thead><tbody>\(rows)</tbody></table></div>
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
                csvEscape(downtime.isEmpty ? event.message : "\(event.message) Downtime: \(downtime)"),
                "",
                "",
                "",
                "",
                ""
            ]
            return cols.joined(separator: ",")
        }.joined(separator: "\n")
    }

    func complianceCSVRows(scope: ReportScope,
                           sessions: [SessionSummary]) -> String {
        complianceFindings(scope: scope, sessions: sessions).map { finding in
            let cols: [String] = [
                "compliance",
                Self.timestampFormatter.string(from: finding.timestamp),
                finding.source?.rawValue ?? "agent_watch",
                finding.source?.label ?? "Agent Watch",
                finding.sessionId ?? finding.id.uuidString,
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
                "",
                finding.severity == "critical" ? "100" : "80",
                finding.severity,
                "agent_watch_coverage",
                csvEscape(finding.title),
                csvEscape(finding.message),
                csvEscape(finding.recommendation),
                "",
                "",
                "",
                "",
                "",
                csvEscape(finding.message),
                "",
                "",
                "",
                "",
                ""
            ]
            return cols.joined(separator: ",")
        }.joined(separator: "\n")
    }

    private func matchEnrollmentKey(_ rawKey: String) -> SupervisorLockKey? {
        let hash = Self.hash(normalized(rawKey))
        return Self.keys.first { $0.enrollmentHash == hash }
    }

    private func applyVerifiedAppOpen(key: SupervisorLockKey) {
        isLocked = true
        lockedByLabel = key.label
        startupVerified = true
        startupVerifiedAt = Date()
        persistLockState()
        appendAudit(kind: .appOpenVerified, keyLabel: key.label,
                    message: "Agent Watch app-open recorded by \(key.label).")
        writeHeartbeat(cleanExit: false)
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

    private func ensureLaunchAtLogin() {
        if #available(macOS 13.0, *) {
            let service = SMAppService.mainApp
            switch service.status {
            case .enabled:
                return
            case .requiresApproval:
                appendAudit(kind: .launchAtLoginNeedsApproval, keyLabel: lockedByLabel,
                            message: "Agent Watch launch-at-login requires approval in macOS Login Items.")
            default:
                do {
                    try service.register()
                    appendAudit(kind: .launchAtLoginEnabled, keyLabel: lockedByLabel,
                                message: "Agent Watch registered itself to open at macOS login.")
                } catch {
                    appendAudit(kind: .launchAtLoginFailed, keyLabel: lockedByLabel,
                                message: "Agent Watch could not register launch-at-login: \(error.localizedDescription)")
                }
            }
        }
    }

    private func writeHeartbeat(cleanExit: Bool) {
        let state = HeartbeatState(
            runId: runId,
            startedAt: runStartedAt,
            heartbeatAt: Date(),
            cleanExit: cleanExit,
            locked: isLocked,
            lockedByLabel: lockedByLabel,
            startupVerified: startupVerified,
            startupVerifiedAt: startupVerifiedAt,
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
            appendPresenceSample(at: state.heartbeatAt)
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

    private func appendPresenceSample(at timestamp: Date) {
        let sample = AgentWatchPresenceSample(
            id: UUID(),
            runId: runId,
            timestamp: timestamp,
            locked: isLocked,
            keyLabel: lockedByLabel,
            startupVerified: startupVerified,
            appVersion: currentVersion
        )
        do {
            let encoder = JSONEncoder()
            encoder.dateEncodingStrategy = .iso8601
            var data = try encoder.encode(sample)
            data.append(0x0A)
            if FileManager.default.fileExists(atPath: presenceURL.path) {
                let handle = try FileHandle(forWritingTo: presenceURL)
                try handle.seekToEnd()
                try handle.write(contentsOf: data)
                try handle.close()
            } else {
                try data.write(to: presenceURL, options: [.atomic])
            }
        } catch {
            NSLog("Agent Watch presence write failed: \(error)")
        }
    }

    private func loadPresenceSamples(in range: ClosedRange<Date>) -> [AgentWatchPresenceSample] {
        guard let raw = try? String(contentsOf: presenceURL, encoding: .utf8) else { return [] }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return raw
            .split(separator: "\n")
            .compactMap { line -> AgentWatchPresenceSample? in
                guard let data = String(line).data(using: .utf8),
                      let sample = try? decoder.decode(AgentWatchPresenceSample.self, from: data),
                      range.contains(sample.timestamp) else {
                    return nil
                }
                return sample
            }
    }

    private func installPowerObservers() {
        guard powerObserverTokens.isEmpty else { return }
        let center = NSWorkspace.shared.notificationCenter
        powerObserverTokens.append(center.addObserver(
            forName: NSWorkspace.willSleepNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in self?.recordPowerEvent(kind: .systemWillSleep) }
        })
        powerObserverTokens.append(center.addObserver(
            forName: NSWorkspace.didWakeNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in self?.recordPowerEvent(kind: .systemDidWake) }
        })
        powerObserverTokens.append(center.addObserver(
            forName: NSWorkspace.willPowerOffNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in self?.recordPowerEvent(kind: .systemWillPowerOff) }
        })
    }

    private func removePowerObservers() {
        let center = NSWorkspace.shared.notificationCenter
        for token in powerObserverTokens {
            center.removeObserver(token)
        }
        powerObserverTokens.removeAll()
    }

    private func recordPowerEvent(kind: SupervisorLockEventKind) {
        let message: String
        switch kind {
        case .systemWillSleep:
            message = "Mac is going to sleep while Agent Watch is running."
        case .systemDidWake:
            message = "Mac woke while Agent Watch is running."
        case .systemWillPowerOff:
            message = "Mac is powering off while Agent Watch is running."
        default:
            message = kind.label
        }
        appendAudit(kind: kind, keyLabel: lockedByLabel, message: message)
        writeHeartbeat(cleanExit: kind == .systemWillPowerOff)
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

    private var presenceURL: URL {
        supportDirectory.appendingPathComponent("app-presence.jsonl")
    }

    private var currentVersion: String {
        Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "dev"
    }

    private func dateRange(for scope: ReportScope) -> ClosedRange<Date> {
        let cal = ReportTime.calendar
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
        formatter.timeZone = ReportTime.timeZone
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
