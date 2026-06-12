// Wrap Sparkle SPUStandardUpdaterController + expose @Observable trạng thái
// "can check now" để bind vào menu Disabled khi check đang chạy.
//
// Sparkle 2 đọc SUFeedURL từ Info.plist nên ở đây không cần config thêm — chỉ
// start updater + lộ method check ra cho menu command.

import Foundation
import Observation
import Sparkle

@Observable
@MainActor
final class UpdaterController {
    /// Sparkle controller — start ngay khi init để auto-check theo schedule
    /// (SUScheduledCheckInterval trong Info.plist, default 1h).
    private let controller: SPUStandardUpdaterController

    /// Mirror canCheckForUpdates để menu item disable đúng lúc.
    var canCheck: Bool = true

    init() {
        // startingUpdater: true → tự bật + tự enqueue check theo schedule.
        // Không gắn delegate — dùng default UI driver (alert + progress).
        self.controller = SPUStandardUpdaterController(
            startingUpdater: true,
            updaterDelegate: nil,
            userDriverDelegate: nil
        )
    }

    /// Gọi từ menu "Check for Updates…" — Sparkle sẽ tự show UI.
    func checkForUpdates() {
        controller.checkForUpdates(nil)
    }
}
