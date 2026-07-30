import SwiftUI

struct SupervisorLockView: View {
    @Environment(SupervisorLockStore.self) private var lock
    @Environment(\.dismiss) private var dismiss
    @State private var secret: String = ""
    @State private var message: String = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            header
            statusCard
            secretInput
            actionRow
        }
        .padding(20)
        .frame(width: 460)
        .background(Claude.background)
        .interactiveDismissDisabled(lock.requiresStartupKey || !lock.isLocked)
    }

    private var header: some View {
        HStack(spacing: 10) {
            Image(systemName: lock.requiresStartupKey ? "key.fill" : (lock.isLocked ? "lock.fill" : "lock.open.fill"))
                .font(.system(size: 17, weight: .semibold))
                .foregroundStyle(lock.requiresStartupKey || lock.isLocked ? Claude.orange : Claude.textMuted)
            VStack(alignment: .leading, spacing: 2) {
                Text("Supervisor Lock")
                    .font(ClaudeFont.heading(18))
                    .foregroundStyle(Claude.textPrimary)
                Text(headerDetail)
                    .font(ClaudeFont.body(11))
                    .foregroundStyle(Claude.textMuted)
            }
            Spacer()
        }
    }

    private var statusCard: some View {
        HStack(spacing: 10) {
            Circle()
                .fill(lock.requiresStartupKey || lock.isLocked ? Claude.orange : Claude.done)
                .frame(width: 9, height: 9)
            VStack(alignment: .leading, spacing: 2) {
                Text(lock.statusLine)
                    .font(ClaudeFont.body(13))
                    .fontWeight(.semibold)
                    .foregroundStyle(Claude.textPrimary)
                Text(statusDetail)
                    .font(ClaudeFont.body(11))
                    .foregroundStyle(Claude.textMuted)
            }
            Spacer()
        }
        .padding(12)
        .background(Claude.surfaceAlt)
        .clipShape(RoundedRectangle(cornerRadius: 8))
    }

    private var secretInput: some View {
        VStack(alignment: .leading, spacing: 6) {
            SectionLabel(text: secretLabel)
            SecureField(secretPlaceholder, text: $secret)
                .textFieldStyle(.roundedBorder)
            if !message.isEmpty {
                Text(message)
                    .font(ClaudeFont.body(11))
                    .foregroundStyle(message.contains("OK") ? Claude.live : Claude.orange)
            }
        }
    }

    private var actionRow: some View {
        HStack {
            if lock.requiresStartupKey {
                Button {
                    if lock.verifyAppOpen(with: secret) {
                        message = "OK - Đã ghi nhận thời gian mở app."
                        secret = ""
                        dismiss()
                    } else {
                        message = "Enrollment key không hợp lệ cho máy này."
                    }
                } label: {
                    Label("Ghi nhận mở app", systemImage: "key.fill")
                }
                .buttonStyle(.borderedProminent)
                .tint(Claude.orange)
            } else if lock.isLocked {
                Button {
                    if lock.disableLock(withUnlockPass: secret) {
                        message = "OK - Lock đã tắt. Nhập enrollment key để khóa lại."
                        secret = ""
                    } else {
                        message = "Unlock pass không hợp lệ."
                    }
                } label: {
                    Label("Tắt lock", systemImage: "lock.open")
                }
                .buttonStyle(.bordered)

                Button {
                    if !lock.authorizeQuit(withUnlockPass: secret, source: "Supervisor Lock panel") {
                        message = "Unlock pass không hợp lệ."
                    }
                } label: {
                    Label("Quit bằng pass", systemImage: "power")
                }
                .buttonStyle(.borderedProminent)
            } else {
                Button {
                    if lock.enableLock(with: secret) {
                        message = "OK - Lock đã bật."
                        secret = ""
                        dismiss()
                    } else {
                        message = "Enrollment key không hợp lệ."
                    }
                } label: {
                    Label("Bật lock", systemImage: "lock")
                }
                .buttonStyle(.borderedProminent)
            }

            Spacer()
            if lock.isLocked {
                Button("Đóng") { dismiss() }
                    .buttonStyle(.borderless)
            }
        }
    }

    private var headerDetail: String {
        if lock.requiresStartupKey {
            return "Nhập enrollment key để ghi log mở app và bắt đầu ngày làm việc."
        }
        return lock.isLocked
            ? "Nhập unlock pass để tắt lock hoặc quit app."
            : "Nhập enrollment key được cấp cho máy này để bật lock."
    }

    private var statusDetail: String {
        if lock.requiresStartupKey {
            return "Heartbeat chỉ hợp lệ sau khi nhập key. Quit/Cmd+Q bị chặn; update được tự restart."
        }
        return lock.isLocked
            ? "Quit/Cmd+Q cần unlock pass. Update tự restart; force quit được ghi nhận qua heartbeat."
            : "App cần được enroll trước; bấm quit khi chưa enroll sẽ bị chặn và ghi audit."
    }

    private var secretLabel: String {
        lock.requiresStartupKey || !lock.isLocked ? "Enrollment key" : "Unlock pass"
    }

    private var secretPlaceholder: String {
        lock.requiresStartupKey || !lock.isLocked ? "AW-LOCK-XXXX-XXXX-XXXX" : "Unlock pass"
    }
}
