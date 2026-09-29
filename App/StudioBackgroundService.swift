import AppKit
import ServiceManagement
import Observation
import Network
import AgentWatchCore

@MainActor @Observable final class StudioBackgroundService {
    static let shared = StudioBackgroundService()
    private var monitor: NWPathMonitor?
    private var wakeObserver: NSObjectProtocol?
    private(set) var message = ""
    private(set) var needsApproval = false
    func start() {
        StudioSyncStore.shared.start()
        if monitor == nil {
            let path = NWPathMonitor(); monitor = path
            path.pathUpdateHandler = { update in
                guard update.status == .satisfied else { return }
                Task { @MainActor in if StudioSyncStore.shared.enabled { await StudioSyncStore.shared.synchronize() } }
            }
            path.start(queue: DispatchQueue(label: "AgentWatch.StudioNetwork"))
            wakeObserver = NSWorkspace.shared.notificationCenter.addObserver(forName: NSWorkspace.didWakeNotification, object: nil, queue: .main) { _ in
                Task { @MainActor in if StudioSyncStore.shared.enabled { await StudioSyncStore.shared.synchronize() } }
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
}
