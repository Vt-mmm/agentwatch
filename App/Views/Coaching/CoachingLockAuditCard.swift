import SwiftUI
import ClaudeWatchCore

extension CoachingReportView {
    var lockAuditCard: some View {
        let events = lockAuditEvents
        let compliance = supervisorLock.complianceFindings(scope: currentScope, sessions: allSessions)
        let forceQuitCount = events.filter { $0.kind == .forceQuitSuspected }.count
        let blockedCount = events.filter { $0.kind == .quitBlocked }.count
        let authorizedCount = events.filter { $0.kind == .quitAuthorized }.count
        return VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 8) {
                Image(systemName: "lock.shield.fill")
                    .foregroundStyle(forceQuitCount > 0 ? .red : Claude.orange)
                Text("Agent Watch audit")
                    .font(ClaudeFont.heading())
                    .foregroundStyle(Claude.textPrimary)
                Spacer()
                Button {
                    showLockAuditLog = true
                } label: {
                    Label("Xem log", systemImage: "list.bullet.rectangle")
                        .font(ClaudeFont.label(10))
                }
                .buttonStyle(.bordered)
                Text(supervisorLock.statusLine)
                    .font(ClaudeFont.mono(10, weight: .semibold))
                    .foregroundStyle(supervisorLock.isLocked ? Claude.orange : Claude.textMuted)
            }

            LazyVGrid(columns: [GridItem(.adaptive(minimum: 120), spacing: 10)],
                      alignment: .leading, spacing: 10) {
                lockMetric("Force quit", "\(forceQuitCount)", tint: forceQuitCount > 0 ? .red : Claude.textPrimary)
                lockMetric("Quit blocked", "\(blockedCount)", tint: blockedCount > 0 ? Claude.orange : Claude.textPrimary)
                lockMetric("Coverage gaps", "\(compliance.count)", tint: compliance.isEmpty ? Claude.textPrimary : .red)
                lockMetric("Authorized", "\(authorizedCount)", tint: Claude.textPrimary)
                lockMetric("Events", "\(events.count)", tint: Claude.textPrimary)
            }

            if !compliance.isEmpty {
                VStack(alignment: .leading, spacing: 6) {
                    ForEach(Array(compliance.prefix(3).enumerated()), id: \.element.id) { _, finding in
                        HStack(alignment: .top, spacing: 8) {
                            Image(systemName: "exclamationmark.triangle.fill")
                                .foregroundStyle(finding.severity == "critical" ? .red : Claude.orange)
                            VStack(alignment: .leading, spacing: 2) {
                                Text(finding.title)
                                    .font(ClaudeFont.body(12))
                                    .fontWeight(.semibold)
                                    .foregroundStyle(Claude.textPrimary)
                                Text(finding.message)
                                    .font(ClaudeFont.body(11))
                                    .foregroundStyle(Claude.textMuted)
                                    .lineLimit(2)
                            }
                        }
                    }
                }
                .padding(10)
                .background(Color.red.opacity(0.08))
                .clipShape(RoundedRectangle(cornerRadius: 8))
            }

            if events.isEmpty {
                Text("Không có app activity event trong khoảng này.")
                    .font(ClaudeFont.body(12))
                    .foregroundStyle(Claude.textMuted)
            } else {
                VStack(spacing: 0) {
                    ForEach(Array(events.prefix(6).enumerated()), id: \.element.id) { idx, event in
                        lockEventRow(event)
                        if idx < min(events.count, 6) - 1 {
                            Divider().background(Claude.border).padding(.leading, 32)
                        }
                    }
                }
            }
        }
        .claudeCard()
    }

    private func lockMetric(_ label: String, _ value: String, tint: Color) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            SectionLabel(text: label)
            Text(value)
                .font(ClaudeFont.mono(17, weight: .semibold))
                .foregroundStyle(tint)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(9)
        .background(Claude.surfaceAlt)
        .clipShape(RoundedRectangle(cornerRadius: 8))
    }

    private func lockEventRow(_ event: SupervisorLockAuditEvent) -> some View {
        HStack(alignment: .top, spacing: 10) {
            ZStack {
                RoundedRectangle(cornerRadius: 7)
                    .fill(lockEventColor(event.kind).opacity(0.16))
                Image(systemName: lockEventIcon(event.kind))
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(lockEventColor(event.kind))
            }
            .frame(width: 26, height: 26)

            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(event.kind.label)
                        .font(ClaudeFont.body(12))
                        .fontWeight(.semibold)
                        .foregroundStyle(Claude.textPrimary)
                    if let key = event.keyLabel {
                        Text(key)
                            .font(ClaudeFont.mono(9, weight: .semibold))
                            .foregroundStyle(Claude.textMuted)
                            .padding(.horizontal, 5)
                            .padding(.vertical, 1)
                            .background(Claude.surfaceAlt, in: Capsule())
                    }
                    Spacer()
                    Text(lockEventTime.string(from: event.timestamp))
                        .font(ClaudeFont.mono(10))
                        .foregroundStyle(Claude.textMuted)
                }
                Text(lockEventDetail(event))
                    .font(ClaudeFont.body(11))
                    .foregroundStyle(Claude.textMuted)
                    .lineLimit(2)
            }
        }
        .padding(.vertical, 7)
        .padding(.horizontal, 2)
    }

    private func lockEventDetail(_ event: SupervisorLockAuditEvent) -> String {
        if let downtime = event.downtimeSeconds {
            return "\(event.message) · downtime \(lockDuration(downtime))"
        }
        return event.message
    }

    private func lockDuration(_ seconds: TimeInterval) -> String {
        let mins = Int(seconds / 60)
        if mins < 1 { return "\(Int(seconds))s" }
        if mins < 60 { return "\(mins)m" }
        return "\(mins / 60)h \(mins % 60)m"
    }

    private func lockEventIcon(_ kind: SupervisorLockEventKind) -> String {
        switch kind {
        case .forceQuitSuspected: return "exclamationmark.triangle.fill"
        case .appOpenKeyRejected: return "key.slash.fill"
        case .appOpenVerified:    return "key.fill"
        case .quitBlocked:        return "hand.raised.fill"
        case .quitAuthorized:     return "checkmark.shield.fill"
        case .lockEnabled:        return "lock.fill"
        case .lockDisabled:       return "lock.open.fill"
        case .cleanQuit:          return "power"
        case .appStarted:         return "play.fill"
        case .systemWillSleep:    return "moon.zzz.fill"
        case .systemDidWake:      return "sun.max.fill"
        case .systemWillPowerOff: return "power.circle.fill"
        case .launchAtLoginEnabled:
            return "arrow.triangle.2.circlepath.circle.fill"
        case .launchAtLoginNeedsApproval:
            return "person.badge.key.fill"
        case .launchAtLoginFailed:
            return "exclamationmark.octagon.fill"
        case .logReadStarted:
            return "doc.text.magnifyingglass"
        case .logReadCompleted:
            return "checkmark.circle.fill"
        case .reportExported:
            return "square.and.arrow.up.fill"
        case .reportExportFailed:
            return "exclamationmark.octagon.fill"
        case .reportExportCancelled:
            return "xmark.circle"
        }
    }

    private func lockEventColor(_ kind: SupervisorLockEventKind) -> Color {
        switch kind {
        case .forceQuitSuspected: return .red
        case .appOpenKeyRejected: return .red
        case .appOpenVerified:    return Claude.live
        case .quitBlocked:        return Claude.orange
        case .quitAuthorized:     return Claude.live
        case .lockEnabled:        return Claude.orange
        case .lockDisabled:       return .purple
        case .cleanQuit:          return Claude.textMuted
        case .appStarted:         return Claude.done
        case .systemWillSleep:    return Claude.textMuted
        case .systemDidWake:      return Claude.done
        case .systemWillPowerOff: return Claude.textMuted
        case .launchAtLoginEnabled:
            return Claude.live
        case .launchAtLoginNeedsApproval:
            return Claude.orange
        case .launchAtLoginFailed:
            return .red
        case .logReadStarted:
            return Claude.orange
        case .logReadCompleted:
            return Claude.done
        case .reportExported:
            return Claude.live
        case .reportExportFailed:
            return .red
        case .reportExportCancelled:
            return Claude.textMuted
        }
    }

    private var lockEventTime: DateFormatter {
        let formatter = DateFormatter()
        formatter.dateFormat = "MM-dd HH:mm"
        formatter.timeZone = ReportTime.timeZone
        return formatter
    }
}

struct LockAuditLogSheet: View {
    let scopeLabel: String
    let events: [SupervisorLockAuditEvent]
    let findings: [WorkComplianceFinding]
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 8) {
                Image(systemName: "list.bullet.rectangle")
                    .foregroundStyle(Claude.orange)
                VStack(alignment: .leading, spacing: 2) {
                    Text("Agent Watch log")
                        .font(ClaudeFont.heading(18))
                        .foregroundStyle(Claude.textPrimary)
                    Text(scopeLabel)
                        .font(ClaudeFont.mono(11))
                        .foregroundStyle(Claude.textMuted)
                }
                Spacer()
                Button("Đóng") { dismiss() }
                    .keyboardShortcut(.escape)
            }

            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    complianceSection
                    auditSection
                }
                .padding(.vertical, 2)
            }
        }
        .padding(20)
        .frame(width: 760, height: 680)
        .background(Claude.background)
    }

    @ViewBuilder
    private var complianceSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            SectionLabel(text: "Coverage compliance")
            if findings.isEmpty {
                emptyRow("Không có coverage violation trong kỳ này.")
            } else {
                ForEach(findings) { finding in
                    complianceRow(finding)
                }
            }
        }
    }

    @ViewBuilder
    private var auditSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            SectionLabel(text: "App activity audit")
            if events.isEmpty {
                emptyRow("Không có app activity event trong kỳ này.")
            } else {
                ForEach(events) { event in
                    auditRow(event)
                }
            }
        }
    }

    private func complianceRow(_ finding: WorkComplianceFinding) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(severityColor(finding.severity))
                .frame(width: 22)
            VStack(alignment: .leading, spacing: 5) {
                HStack(spacing: 6) {
                    Text(finding.title)
                        .font(ClaudeFont.body(13))
                        .fontWeight(.semibold)
                        .foregroundStyle(Claude.textPrimary)
                    Text(finding.severity.uppercased())
                        .font(ClaudeFont.mono(9, weight: .bold))
                        .foregroundStyle(severityColor(finding.severity))
                        .padding(.horizontal, 5)
                        .padding(.vertical, 1)
                        .background(severityColor(finding.severity).opacity(0.12), in: Capsule())
                    Spacer()
                    Text(fullTime(finding.timestamp))
                        .font(ClaudeFont.mono(10))
                        .foregroundStyle(Claude.textMuted)
                }
                Text(finding.message)
                    .font(ClaudeFont.body(12))
                    .foregroundStyle(Claude.textMuted)
                    .textSelection(.enabled)
                Text(finding.recommendation)
                    .font(ClaudeFont.body(11))
                    .foregroundStyle(Claude.orange)
                    .textSelection(.enabled)
                HStack(spacing: 6) {
                    Text(finding.source?.label ?? "Agent Watch")
                    if let sessionId = finding.sessionId {
                        Text(String(sessionId.suffix(12)))
                    }
                }
                .font(ClaudeFont.mono(10))
                .foregroundStyle(Claude.textMuted.opacity(0.85))
            }
        }
        .padding(10)
        .background(severityColor(finding.severity).opacity(0.07))
        .clipShape(RoundedRectangle(cornerRadius: 8))
    }

    private func auditRow(_ event: SupervisorLockAuditEvent) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: icon(for: event.kind))
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(eventColor(event.kind))
                .frame(width: 22)
            VStack(alignment: .leading, spacing: 5) {
                HStack(spacing: 6) {
                    Text(event.kind.label)
                        .font(ClaudeFont.body(13))
                        .fontWeight(.semibold)
                        .foregroundStyle(Claude.textPrimary)
                    if let key = event.keyLabel {
                        Text(key)
                            .font(ClaudeFont.mono(9, weight: .semibold))
                            .foregroundStyle(Claude.textMuted)
                            .padding(.horizontal, 5)
                            .padding(.vertical, 1)
                            .background(Claude.surfaceAlt, in: Capsule())
                    }
                    Spacer()
                    Text(fullTime(event.timestamp))
                        .font(ClaudeFont.mono(10))
                        .foregroundStyle(Claude.textMuted)
                }
                Text(event.message)
                    .font(ClaudeFont.body(12))
                    .foregroundStyle(Claude.textMuted)
                    .textSelection(.enabled)
                if let downtime = event.downtimeSeconds {
                    Text("Downtime \(duration(downtime))")
                        .font(ClaudeFont.mono(10))
                        .foregroundStyle(Claude.orange)
                }
            }
        }
        .padding(10)
        .background(Claude.surfaceAlt)
        .clipShape(RoundedRectangle(cornerRadius: 8))
    }

    private func emptyRow(_ text: String) -> some View {
        Text(text)
            .font(ClaudeFont.body(12))
            .foregroundStyle(Claude.textMuted)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(10)
            .background(Claude.surfaceAlt)
            .clipShape(RoundedRectangle(cornerRadius: 8))
    }

    private func severityColor(_ severity: String) -> Color {
        switch severity {
        case "critical": return .purple
        case "high":     return .red
        case "medium":   return Claude.orange
        default:         return Claude.textMuted
        }
    }

    private func eventColor(_ kind: SupervisorLockEventKind) -> Color {
        switch kind {
        case .forceQuitSuspected, .appOpenKeyRejected, .launchAtLoginFailed, .reportExportFailed:
            return .red
        case .quitBlocked, .lockEnabled, .launchAtLoginNeedsApproval, .logReadStarted:
            return Claude.orange
        case .appOpenVerified, .quitAuthorized, .launchAtLoginEnabled,
             .logReadCompleted, .reportExported:
            return Claude.live
        case .lockDisabled:
            return .purple
        case .cleanQuit, .systemWillSleep, .systemWillPowerOff, .reportExportCancelled:
            return Claude.textMuted
        case .appStarted, .systemDidWake:
            return Claude.done
        }
    }

    private func icon(for kind: SupervisorLockEventKind) -> String {
        switch kind {
        case .forceQuitSuspected: return "exclamationmark.triangle.fill"
        case .appOpenKeyRejected: return "key.slash.fill"
        case .appOpenVerified:    return "key.fill"
        case .quitBlocked:        return "hand.raised.fill"
        case .quitAuthorized:     return "checkmark.shield.fill"
        case .lockEnabled:        return "lock.fill"
        case .lockDisabled:       return "lock.open.fill"
        case .cleanQuit:          return "power"
        case .appStarted:         return "play.fill"
        case .systemWillSleep:    return "moon.zzz.fill"
        case .systemDidWake:      return "sun.max.fill"
        case .systemWillPowerOff: return "power.circle.fill"
        case .launchAtLoginEnabled:
            return "arrow.triangle.2.circlepath.circle.fill"
        case .launchAtLoginNeedsApproval:
            return "person.badge.key.fill"
        case .launchAtLoginFailed:
            return "exclamationmark.octagon.fill"
        case .logReadStarted:
            return "doc.text.magnifyingglass"
        case .logReadCompleted:
            return "checkmark.circle.fill"
        case .reportExported:
            return "square.and.arrow.up.fill"
        case .reportExportFailed:
            return "exclamationmark.octagon.fill"
        case .reportExportCancelled:
            return "xmark.circle"
        }
    }

    private func fullTime(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd HH:mm:ss"
        formatter.timeZone = ReportTime.timeZone
        return formatter.string(from: date)
    }

    private func duration(_ seconds: TimeInterval) -> String {
        let mins = Int(seconds / 60)
        if mins < 1 { return "\(Int(seconds))s" }
        if mins < 60 { return "\(mins)m" }
        return "\(mins / 60)h \(mins % 60)m"
    }
}
