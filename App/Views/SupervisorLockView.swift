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
        .interactiveDismissDisabled(!lock.isLocked)
    }

    private var header: some View {
        HStack(spacing: 10) {
            Image(systemName: lock.isLocked ? "lock.fill" : "lock.open.fill")
                .font(.system(size: 17, weight: .semibold))
                .foregroundStyle(lock.isLocked ? Claude.orange : Claude.textMuted)
            VStack(alignment: .leading, spacing: 2) {
                Text("Supervisor Lock")
                    .font(ClaudeFont.heading(18))
                    .foregroundStyle(Claude.textPrimary)
                Text(lock.isLocked
                     ? "Nhập unlock pass để tắt lock hoặc quit app."
                     : "Nhập enrollment key được cấp cho máy này để bật lock.")
                    .font(ClaudeFont.body(11))
                    .foregroundStyle(Claude.textMuted)
            }
            Spacer()
        }
    }

    private var statusCard: some View {
        HStack(spacing: 10) {
            Circle()
                .fill(lock.isLocked ? Claude.orange : Claude.done)
                .frame(width: 9, height: 9)
            VStack(alignment: .leading, spacing: 2) {
                Text(lock.statusLine)
                    .font(ClaudeFont.body(13))
                    .fontWeight(.semibold)
                    .foregroundStyle(Claude.textPrimary)
                Text(lock.isLocked
                     ? "Quit/Cmd+Q yêu cầu unlock pass riêng. Force quit sẽ bị ghi nhận theo heartbeat."
                     : "App cần được enroll trước; bấm quit khi chưa enroll sẽ bị chặn và ghi audit.")
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
            SectionLabel(text: lock.isLocked ? "Unlock pass" : "Enrollment key")
            SecureField(lock.isLocked ? "Unlock pass" : "AW-LOCK-XXXX-XXXX-XXXX", text: $secret)
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
            if lock.isLocked {
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
}
