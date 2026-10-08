import AppKit
import ServiceManagement
import Observation
import Network
import AgentWatchCore

@MainActor @Observable final class StudioBackgroundService {
    static let shared = StudioBackgroundService()
    private var monitor: NWPathMonitor?
    private var wakeObserver: NSObjectProtocol?
    private var keychainWatch: Task<Void, Never>?
    private var keychainAskAfter = Date.distantPast
    static let keychainRemindAfter: TimeInterval = 3600
    private(set) var message = ""
    private(set) var needsApproval = false
    /// Answers the direct helper when the running app has Keychain access.
    /// Signing changes may still require renewed approval in the app.
    private let credentials = StudioCredentialServer { profileID in
        DispatchQueue.main.sync { MainActor.assumeIsolated { StudioCredentialCommand.savedKey(profileID: profileID) } }
    }
    func start() {
        credentials.start()
        // Status reports go to the employee's own Studio after each sync; the
        // same payload is shown in Diagnostics. Launch state is reported as a code.
        StudioSyncStore.shared.statusReporting = true
        StudioSyncStore.shared.launchAtLoginStatus = {
            switch SMAppService.mainApp.status {
            case .enabled: "enabled"
            case .requiresApproval: "requires_approval"
            default: "unavailable"
            }
        }
        StudioSyncStore.shared.start()
        if monitor == nil {
            let path = NWPathMonitor(); monitor = path
            path.pathUpdateHandler = { update in
                guard update.status == .satisfied else { return }
                Task { @MainActor in await StudioSyncStore.shared.synchronizeSavedProfiles() }
            }
            path.start(queue: DispatchQueue(label: "AgentWatch.StudioNetwork"))
            wakeObserver = NSWorkspace.shared.notificationCenter.addObserver(forName: NSWorkspace.didWakeNotification, object: nil, queue: .main) { _ in
                Task { @MainActor in await StudioSyncStore.shared.synchronizeSavedProfiles() }
            }
        }
        // A key macOS will not let the background sync read (often right after
        // an update) leaves Piagent's company mode stale: say so in a dialog.
        if keychainWatch == nil {
            keychainWatch = Task { @MainActor [weak self] in
                while !Task.isCancelled {
                    try? await Task.sleep(for: .seconds(60))
                    await self?.offerKeychainApproval()
                }
            }
        }
        // Reuse the application's existing login-item owner and audit trail.
        SupervisorLockStore.shared.ensureLaunchAtLogin()
        let status = SMAppService.mainApp.status
        needsApproval = status == .requiresApproval
        switch status {
        case .enabled: message = "Chạy nền · tự mở khi đăng nhập máy."
        case .requiresApproval: message = "Cần bật AgentWatch trong Login Items để tự chạy sau khi đăng nhập."
        default: message = "Đang chạy nền; chưa đăng ký được tự mở khi đăng nhập."
        }
    }
    func openSettings() { SMAppService.openSystemSettingsLoginItems() }

    private var askingKeychain = false
    func offerKeychainApproval() async {
        let sync = StudioSyncStore.shared
        guard sync.needsKeychainApproval, !askingKeychain, Date() >= keychainAskAfter else { return }
        askingKeychain = true; defer { askingKeychain = false }
        NSApp.activate(ignoringOtherApps: true)
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = "Agent Watch cần quyền đọc key công ty"
        alert.informativeText = "macOS cần bạn cho phép Agent Watch đọc key Studio trong Keychain (thường sau khi Agent Watch cập nhật). "
            + "Trong lúc chờ, chế độ công ty của Piagent (Terminal và dashboard) chưa mở được.\n\n"
            + "Bấm “Cho phép ngay”, rồi chọn “Luôn cho phép” trong hộp thoại của macOS."
        alert.addButton(withTitle: "Cho phép ngay")
        alert.addButton(withTitle: "Để sau")
        guard alert.runModal() == .alertFirstButtonReturn else { keychainAskAfter = Date().addingTimeInterval(Self.keychainRemindAfter); return }
        if await sync.authorizeKeychain() {
            let done = NSAlert()
            done.messageText = "Đã cho phép"
            done.informativeText = "Agent Watch đã cập nhật cấu hình cho Piagent. Mở lại Piagent nếu nó đang báo lỗi công ty."
            done.runModal()
        } else {
            keychainAskAfter = Date().addingTimeInterval(300)
        }
    }
}
