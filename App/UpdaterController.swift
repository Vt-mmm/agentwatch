// Wrap Sparkle SPUStandardUpdaterController + expose @Observable trạng thái
// "can check now" để bind vào menu Disabled khi check đang chạy.
//
// Sparkle 2 đọc SUFeedURL từ Info.plist nên ở đây không cần config thêm — chỉ
// start updater + lộ method check ra cho menu command.

import Foundation
import Observation
import Sparkle

/// Delegate bỏ qua first-launch prompt "Do you want to automatically check for
/// updates?" — auto-check luôn từ launch đầu. User vẫn có thể tắt qua Settings.
private final class UpdaterDelegate: NSObject, SPUUpdaterDelegate {
    nonisolated func updaterShouldPromptForPermissionToCheck(forUpdates updater: SPUUpdater) -> Bool {
        false   // skip permission dialog
    }

    nonisolated func updaterWillRelaunchApplication(_ updater: SPUUpdater) {
        let authorizeRelaunch = {
            MainActor.assumeIsolated {
                SupervisorLockStore.shared.authorizeUpdateRelaunch()
            }
        }
        if Thread.isMainThread {
            authorizeRelaunch()
        } else {
            DispatchQueue.main.sync(execute: authorizeRelaunch)
        }
    }
}

@Observable
@MainActor
final class UpdaterController {
    private let controller: SPUStandardUpdaterController
    private let delegate = UpdaterDelegate()

    var canCheck: Bool = true

    /// Version hiện tại để show trong Settings menu.
    var currentVersion: String {
        let short = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "?"
        let build = Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "?"
        return "\(short) (\(build))"
    }

    init() {
        self.controller = SPUStandardUpdaterController(
            startingUpdater: true,
            updaterDelegate: delegate,
            userDriverDelegate: nil
        )
        // Force enable + check ngay khi launch — đảm bảo team thấy update mới ngay.
        controller.updater.automaticallyChecksForUpdates = true
    }

    /// Gọi từ menu "Check for Updates…" — Sparkle tự show UI (popup có/không update).
    func checkForUpdates() {
        controller.checkForUpdates(nil)
    }
}
