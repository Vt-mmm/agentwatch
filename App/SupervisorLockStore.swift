import AppKit
import Carbon
import Foundation
import Observation
import ServiceManagement
import AgentWatchCore

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

    // The legacy type/file and audit wire fields remain for historical reports.
    // App startup and termination no longer authenticate an enrollment key.
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

    private let heartbeatInterval: TimeInterval = 60
    private let runId = UUID()
    private let runStartedAt = Date()

    private var started = false
    private var heartbeatTimer: Timer?
    private var powerObserverTokens: [NSObjectProtocol] = []
    private var didMarkCleanExit = false

    // Kept only as legacy heartbeat fields; they never govern access.
    let isLocked = false
    var lockedByLabel: String? { reportIdentity?.name }
    let startupVerified = false
    private let startupVerifiedAt: Date? = nil
    var lastHeartbeatAt: Date?
    var recentEvents: [SupervisorLockAuditEvent] = []
    private(set) var reportIdentity: ReportEnrollmentIdentity?
    var collectionIdentity: ReportEnrollmentIdentity? { reportIdentity }

    private let supportOverride: URL?
    init(defaults: UserDefaults = .standard, directory: URL? = nil) {
        supportOverride = directory
        reportIdentity = try? ReportEnrollmentIdentity.local(defaults: defaults, deviceName: Host.current().localizedName ?? "Máy này")
        defaults.removeObject(forKey: "supervisor.lock.enabled")
        defaults.removeObject(forKey: "supervisor.lock.byLabel")
    }

    var statusLine: String { "Đang chạy nền" }

    var loginItemStatus: String {
        switch SMAppService.mainApp.status {
        case .enabled: "Tự mở khi đăng nhập: đã bật"
        case .requiresApproval: "Tự mở khi đăng nhập: cần bật trong Cài đặt macOS"
        default: "Tự mở khi đăng nhập: chưa bật; cần kiểm tra Mục đăng nhập"
        }
    }

    func openLoginSettings() { SMAppService.openSystemSettingsLoginItems() }

    func start() {
        guard !started else { return }
        started = true
        recentEvents = loadAuditEvents(limit: 200)
        detectPreviousAbnormalShutdown()
        appendAudit(kind: .appStarted, keyLabel: lockedByLabel,
                    message: "AgentWatch opened; background activity recording started.")
        ensureLaunchAtLogin()
        writeHeartbeat(cleanExit: false)
        installPowerObservers()
        heartbeatTimer = Timer.scheduledTimer(withTimeInterval: heartbeatInterval, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.writeHeartbeat(cleanExit: false) }
        }
    }

    func requestQuit(source: String = "ui") { NSApp.terminate(nil) }

    func shouldTerminate(source: String) -> NSApplication.TerminateReply {
        markCleanExit(source: source)
        return .terminateNow
    }

    func markCleanExit(source: String) {
        guard !didMarkCleanExit else { return }
        didMarkCleanExit = true
        heartbeatTimer?.invalidate()
        heartbeatTimer = nil
        removePowerObservers()
        writeHeartbeat(cleanExit: true)
        appendAudit(kind: .cleanQuit, keyLabel: nil,
                    message: "AgentWatch quit cleanly from \(source).")
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
            message: "reason=\(reason); scope=\(scope.label); language=\(AgentWatchLocale.languageCode); region=\(AgentWatchLocale.regionCode); locale=\(AgentWatchLocale.identifier); timezone=\(ReportTime.timeZoneLabel)"
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
        let verifiedSamples = samples
        var findings: [WorkComplianceFinding] = []

        if !sessions.isEmpty && verifiedSamples.isEmpty {
            findings.append(WorkComplianceFinding(
                id: UUID(),
                timestamp: range.lowerBound,
                severity: "info",
                title: "Chưa có dữ liệu Agent Watch",
                message: "Có phiên CLI trong kỳ nhưng chưa ghi nhận Agent Watch đang chạy.",
                recommendation: "Mở Agent Watch để ghi nhận hoạt động trên máy.",
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
                    title = "Session finished before AgentWatch opened"
                    message = "\(session.source.label) session '\(session.displayTitle)' đã chạy xong trước khi Agent Watch được mở."
                    recommendation = "Kiểm tra trạng thái tự mở Agent Watch trong Mục đăng nhập của macOS."
                } else {
                    title = "Agent session outside app coverage"
                    message = "\(session.source.label) session '\(session.displayTitle)' chưa có dữ liệu Agent Watch trong lúc chạy."
                    recommendation = "Đối chiếu thời gian chạy app; khoảng thiếu dữ liệu không chứng minh người dùng vi phạm."
                }
                findings.append(WorkComplianceFinding(
                    id: UUID(),
                    timestamp: first,
                    severity: "info",
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
        var md = "\n## AgentWatch activity audit\n"
        if scoped.isEmpty {
            md += "_Không có app activity event trong khoảng này._\n"
            return md
        }
        md += "| Time | Event | Name | Downtime | Message |\n"
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
        var md = "\n## AgentWatch coverage\n"
        if findings.isEmpty {
            md += "_Không có khoảng thiếu dữ liệu trong kỳ này._\n"
            return md
        }
        md += "| Severity | Time | Source | Session | Finding | Recommendation |\n"
        md += "|---|---|---|---|---|---|\n"
        for finding in findings {
            md += "| \(finding.severity) | \(Self.timestampFormatter.string(from: finding.timestamp)) | \(finding.source?.label ?? "AgentWatch") | \(finding.sessionId ?? "") | \(finding.message) | \(finding.recommendation) |\n"
        }
        return md
    }

    func htmlSection(scope: ReportScope) -> String {
        let scoped = events(in: scope)
        guard !scoped.isEmpty else {
            return "<h2>AgentWatch activity audit</h2><p class=muted>Không có app activity event trong khoảng này.</p>"
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
        <h2>AgentWatch activity audit</h2>
        <div class="table-scroll"><table class="wide-table"><thead><tr><th>Time (\(ReportTime.timeZoneLabel))</th><th>Event</th><th>Name</th><th>Downtime</th><th>Message</th></tr></thead><tbody>\(rows)</tbody></table></div>
        """
    }

    func complianceHTMLSection(scope: ReportScope,
                               sessions: [SessionSummary]) -> String {
        let findings = complianceFindings(scope: scope, sessions: sessions)
        guard !findings.isEmpty else {
            return "<h2>AgentWatch coverage</h2><p class=muted>Không có khoảng thiếu dữ liệu trong kỳ này.</p>"
        }
        let rows = findings.map { finding in
            "<tr><td>\(htmlEscape(finding.severity))</td>"
                + "<td>\(htmlEscape(Self.timestampFormatter.string(from: finding.timestamp)))</td>"
                + "<td>\(htmlEscape(finding.source?.label ?? "AgentWatch"))</td>"
                + "<td>\(htmlEscape(finding.sessionId ?? ""))</td>"
                + "<td>\(htmlEscape(finding.message))</td>"
                + "<td>\(htmlEscape(finding.recommendation))</td></tr>"
        }.joined()
        return """
        <h2>AgentWatch coverage</h2>
        <div class="table-scroll"><table class="wide-table risk-table"><thead><tr><th>Severity</th><th>Time (\(ReportTime.timeZoneLabel))</th><th>Source</th><th>Session</th><th>Finding</th><th>Recommendation</th></tr></thead><tbody>\(rows)</tbody></table></div>
        """
    }

    func csvRows(scope: ReportScope) -> String {
        events(in: scope).map { event in
            let downtime = event.downtimeSeconds.map { humanDuration($0) } ?? ""
            let title = event.kind.label
            let recommendation: String
            switch event.kind {
            case .forceQuitSuspected:
                recommendation = "Check for an app crash, system shutdown or interrupted update."
            case .quitBlocked:
                recommendation = "Historical event from the retired supervisor lock."
            default:
                recommendation = ""
            }
            let cols: [String] = [
                "lock_audit",
                Self.timestampFormatter.string(from: event.timestamp),
                "agent_watch",
                "AgentWatch",
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
                finding.source?.label ?? "AgentWatch",
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

    func ensureLaunchAtLogin() {
        if #available(macOS 13.0, *) {
            let service = SMAppService.mainApp
            switch service.status {
            case .enabled:
                // Moving out of a temporary build directory must update the
                // registered URL, otherwise login may reopen the obsolete build.
                let path = Bundle.main.bundleURL.resolvingSymlinksInPath().path
                if UserDefaults.standard.string(forKey: "supervisor.login.registeredPath") != path {
                    do {
                        try service.unregister()
                        try service.register()
                        UserDefaults.standard.set(path, forKey: "supervisor.login.registeredPath")
                        appendAudit(kind: .launchAtLoginEnabled, keyLabel: lockedByLabel,
                                    message: "AgentWatch updated its login item to the current installed app.")
                    } catch {
                        appendAudit(kind: .launchAtLoginFailed, keyLabel: lockedByLabel,
                                    message: "AgentWatch could not update its login item: \(error.localizedDescription)")
                    }
                }
                return
            case .requiresApproval:
                appendAudit(kind: .launchAtLoginNeedsApproval, keyLabel: lockedByLabel,
                            message: "AgentWatch launch-at-login requires approval in macOS Login Items.")
            default:
                do {
                    try service.register()
                    UserDefaults.standard.set(Bundle.main.bundleURL.resolvingSymlinksInPath().path, forKey: "supervisor.login.registeredPath")
                    appendAudit(kind: .launchAtLoginEnabled, keyLabel: lockedByLabel,
                                message: "AgentWatch registered itself to open at macOS login.")
                } catch {
                    appendAudit(kind: .launchAtLoginFailed, keyLabel: lockedByLabel,
                                message: "AgentWatch could not register launch-at-login: \(error.localizedDescription)")
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
            NSLog("AgentWatch heartbeat write failed: \(error)")
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
            NSLog("AgentWatch presence write failed: \(error)")
        }
    }

    private func loadPresenceSamples(in range: Range<Date>) -> [AgentWatchPresenceSample] {
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
            message = "Mac is going to sleep while AgentWatch is running."
        case .systemDidWake:
            message = "Mac woke while AgentWatch is running."
        case .systemWillPowerOff:
            message = "Mac is powering off while AgentWatch is running."
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
            NSLog("AgentWatch lock audit write failed: \(error)")
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

    private var supportDirectory: URL {
        supportOverride ?? AgentWatchIdentity.applicationSupportDirectory()
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

    private func dateRange(for scope: ReportScope) -> Range<Date> {
        ReportTime.range(for: scope)
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
    private var launchedAtLogin = false
    static func isLoginLaunch(_ event: NSAppleEventDescriptor?) -> Bool {
        event?.eventID == kAEOpenApplication && event?.paramDescriptor(forKeyword: keyAEPropData)?.enumCodeValue == keyAELaunchedAsLogInItem
    }
    func applicationWillFinishLaunching(_ notification: Notification) {
        launchedAtLogin = Self.isLoginLaunch(NSAppleEventManager.shared().currentAppleEvent)
    }
    func applicationShouldOpenUntitledFile(_ sender: NSApplication) -> Bool { !launchedAtLogin }
    func applicationDidFinishLaunching(_ notification: Notification) {
        StudioBackgroundService.shared.start()
        SupervisorLockStore.shared.start()
        DesktopAppActivityCollector.shared.start()
        launchedAtLogin = launchedAtLogin || Self.isLoginLaunch(NSAppleEventManager.shared().currentAppleEvent)
        if launchedAtLogin {
            // Login starts the menu-bar/background services without taking focus.
            DispatchQueue.main.async { NSApp.hide(nil) }
        }
    }
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        SupervisorLockStore.shared.shouldTerminate(source: "application")
    }

    func applicationWillTerminate(_ notification: Notification) {
        DesktopAppActivityCollector.shared.stopAndFlush()
        SupervisorLockStore.shared.markCleanExit(source: "applicationWillTerminate")
    }
}
