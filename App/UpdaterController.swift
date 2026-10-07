// Wrap Sparkle SPUStandardUpdaterController + expose @Observable trạng thái
// "can check now" để bind vào menu Disabled khi check đang chạy.
//
// Sparkle 2 đọc SUFeedURL từ Info.plist nên ở đây không cần config thêm — chỉ
// start updater + lộ method check ra cho menu command.
//
// Bản mới phải được nói rõ: Sparkle tự tải ngầm rồi chỉ cài khi thoát app, mà
// Agent Watch gần như không bao giờ thoát, và Sparkle chỉ nhắc sau 1 tuần. Khi
// bản mới đã tải xong, Watch hỏi ngay bằng dialog "Cập nhật ngay / Để sau";
// "Để sau" hỏi lại sau 1 giờ.

import AppKit
import Foundation
import Observation
import Sparkle

/// Sparkle hands the install block to a nonisolated callback; it is only
/// ever called back on the main actor.
struct InstallBlock: @unchecked Sendable { let run: () -> Void }

/// Delegate bỏ qua first-launch prompt "Do you want to automatically check for
/// updates?" — auto-check luôn từ launch đầu. User vẫn có thể tắt qua Settings.
private final class UpdaterDelegate: NSObject, SPUUpdaterDelegate, @unchecked Sendable {
    @MainActor var onReadyToInstall: ((_ version: String, _ install: InstallBlock) -> Void)?

    nonisolated func updaterShouldPromptForPermissionToCheck(forUpdates updater: SPUUpdater) -> Bool {
        false   // skip permission dialog
    }

    nonisolated func updater(_ updater: SPUUpdater, willInstallUpdateOnQuit item: SUAppcastItem,
                             immediateInstallationBlock immediateInstallHandler: @escaping () -> Void) -> Bool {
        let version = item.displayVersionString
        let install = InstallBlock(run: immediateInstallHandler)
        Task { @MainActor in self.onReadyToInstall?(version, install) }
        return true   // Watch hỏi người dùng; vẫn cài khi thoát nếu họ chọn để sau
    }
}

@Observable
@MainActor
final class UpdaterController {
    private let controller: SPUStandardUpdaterController
    private let delegate = UpdaterDelegate()
    private var reminder: Timer?

    static let remindAfter: TimeInterval = 3600

    var canCheck: Bool = true

    /// Version hiện tại để show trong Settings menu.
    var currentVersion: String {
        let short = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "?"
        let build = Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "?"
        return "\(short) (\(build))"
    }

    init() {
        self.controller = SPUStandardUpdaterController(
            startingUpdater: false,
            updaterDelegate: delegate,
            userDriverDelegate: nil
        )
        delegate.onReadyToInstall = { [weak self] version, install in self?.offer(version: version, install: install) }
        controller.startUpdater()
        // Force enable + check ngay khi launch — đảm bảo team thấy update mới ngay.
        controller.updater.automaticallyChecksForUpdates = true
        // Tải ngầm trên mọi máy để bản mới luôn đi qua dialog bên dưới.
        controller.updater.automaticallyDownloadsUpdates = true
    }

    /// Gọi từ menu "Check for Updates…" — Sparkle tự show UI (popup có/không update).
    func checkForUpdates() {
        controller.checkForUpdates(nil)
    }

    private func offer(version: String, install: InstallBlock) {
        reminder?.invalidate()
        reminder = nil
        NSApp.activate(ignoringOtherApps: true)
        let alert = NSAlert()
        alert.alertStyle = .informational
        alert.messageText = "Có bản Agent Watch mới: \(version)"
        alert.informativeText = "Bản mới đã tải xong. Cập nhật ngay sẽ đóng và mở lại Agent Watch (khoảng vài giây); "
            + "nên cập nhật khi không có cuộc trò chuyện công ty đang chạy. "
            + "Nếu chọn để sau, Agent Watch nhắc lại sau 1 giờ và vẫn tự cập nhật khi bạn thoát app."
        alert.addButton(withTitle: "Cập nhật ngay")
        alert.addButton(withTitle: "Để sau")
        if alert.runModal() == .alertFirstButtonReturn {
            install.run()
            return
        }
        reminder = Timer.scheduledTimer(withTimeInterval: Self.remindAfter, repeats: false) { [weak self] _ in
            Task { @MainActor in self?.offer(version: version, install: install) }
        }
    }
}
