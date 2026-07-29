import SwiftUI

extension CoachingReportView {
    var lockAuditCard: some View {
        let events = lockAuditEvents
        let forceQuitCount = events.filter { $0.kind == .forceQuitSuspected }.count
        let blockedCount = events.filter { $0.kind == .quitBlocked }.count
        let authorizedCount = events.filter { $0.kind == .quitAuthorized }.count
        return VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 8) {
                Image(systemName: "lock.shield.fill")
                    .foregroundStyle(forceQuitCount > 0 ? .red : Claude.orange)
                Text("Lock audit")
                    .font(ClaudeFont.heading())
                    .foregroundStyle(Claude.textPrimary)
                Spacer()
                Text(supervisorLock.statusLine)
                    .font(ClaudeFont.mono(10, weight: .semibold))
                    .foregroundStyle(supervisorLock.isLocked ? Claude.orange : Claude.textMuted)
            }

            LazyVGrid(columns: [GridItem(.adaptive(minimum: 120), spacing: 10)],
                      alignment: .leading, spacing: 10) {
                lockMetric("Force quit", "\(forceQuitCount)", tint: forceQuitCount > 0 ? .red : Claude.textPrimary)
                lockMetric("Quit blocked", "\(blockedCount)", tint: blockedCount > 0 ? Claude.orange : Claude.textPrimary)
                lockMetric("Authorized", "\(authorizedCount)", tint: Claude.textPrimary)
                lockMetric("Events", "\(events.count)", tint: Claude.textPrimary)
            }

            if events.isEmpty {
                Text("Không có lock/quit event trong khoảng này.")
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
        case .quitBlocked:        return "hand.raised.fill"
        case .quitAuthorized:     return "checkmark.shield.fill"
        case .lockEnabled:        return "lock.fill"
        case .lockDisabled:       return "lock.open.fill"
        case .cleanQuit:          return "power"
        case .appStarted:         return "play.fill"
        }
    }

    private func lockEventColor(_ kind: SupervisorLockEventKind) -> Color {
        switch kind {
        case .forceQuitSuspected: return .red
        case .quitBlocked:        return Claude.orange
        case .quitAuthorized:     return Claude.live
        case .lockEnabled:        return Claude.orange
        case .lockDisabled:       return .purple
        case .cleanQuit:          return Claude.textMuted
        case .appStarted:         return Claude.done
        }
    }

    private var lockEventTime: DateFormatter {
        let formatter = DateFormatter()
        formatter.dateFormat = "MM-dd HH:mm"
        formatter.timeZone = .current
        return formatter
    }
}
