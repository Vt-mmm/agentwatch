// NSWindow transparent always-on-top làm desktop pet overlay.
// SwiftUI WindowGroup không cho phép borderless + transparent + level=.floating,
// nên dùng NSWindow trực tiếp + NSHostingView để embed SwiftUI.
//
// Vị trí pet persist qua UserDefaults — lần mở app sau, pet ngồi đúng chỗ cũ.

import AppKit
import SwiftUI
import Observation
import ClaudeWatchCore

@Observable
@MainActor
final class FloatingPetController {
    /// Toggle hiển thị floating pet. Bind từ Settings menu.
    var isVisible: Bool = false {
        didSet { syncWindow() }
    }

    /// PetState hiện tại — caller cập nhật từ CoachingDataStore tick.
    var state: PetState = .happy { didSet { refresh() } }

    /// Talk bubble — set non-nil để pet "nói", tự nil sau dismissAfterSec.
    var talk: PetTalk? = nil { didSet { refresh() } }

    /// Character sprite name (char00..char26). Caller sync từ SpriteStore.
    var characterName: String = "char01" { didSet { refresh() } }

    private var window: NSWindow?
    private var dismissTask: Task<Void, Never>?
    private let frameKey = "FloatingPetController.frame"

    init() {
        // Restore visibility từ UserDefaults — pet stays hidden cho tới khi
        // user explicit bật. Tránh annoying first-launch.
        isVisible = UserDefaults.standard.bool(forKey: "FloatingPetController.visible")
        if isVisible { syncWindow() }
    }

    /// Set talk message + auto-dismiss sau N giây.
    func say(_ talk: PetTalk, dismissAfter: TimeInterval = 5) {
        self.talk = talk
        dismissTask?.cancel()
        dismissTask = Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(dismissAfter * 1_000_000_000))
            guard !Task.isCancelled else { return }
            self?.talk = nil
        }
    }

    func toggle() {
        isVisible.toggle()
        UserDefaults.standard.set(isVisible, forKey: "FloatingPetController.visible")
    }

    private func syncWindow() {
        if isVisible {
            if window == nil { createWindow() }
            window?.orderFront(nil)
        } else {
            window?.orderOut(nil)
        }
    }

    private func refresh() {
        guard let win = window,
              let host = win.contentView as? NSHostingView<FloatingPetView> else { return }
        host.rootView = FloatingPetView(state: state, talk: talk,
                                         characterName: characterName)
    }

    private func createWindow() {
        let initialSize = NSRect(x: 0, y: 0, width: 260, height: 160)
        let win = NSPanel(
            contentRect: initialSize,
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false)
        win.isOpaque = false
        win.backgroundColor = .clear
        win.hasShadow = false
        win.level = .floating
        win.isMovableByWindowBackground = true
        win.collectionBehavior = [.canJoinAllSpaces, .stationary, .fullScreenAuxiliary]
        win.ignoresMouseEvents = false
        win.hidesOnDeactivate = false

        let host = NSHostingView(rootView: FloatingPetView(state: state, talk: talk,
                                                            characterName: characterName))
        host.translatesAutoresizingMaskIntoConstraints = true
        host.autoresizingMask = [.width, .height]
        host.frame = win.contentView?.bounds ?? initialSize
        win.contentView = host

        // Restore frame nếu user đã di chuyển trước đó, else đặt góc dưới phải
        // màn hình primary để không che workspace.
        if let saved = UserDefaults.standard.string(forKey: frameKey) {
            win.setFrame(NSRectFromString(saved), display: false)
        } else if let screen = NSScreen.main {
            let r = screen.visibleFrame
            win.setFrameTopLeftPoint(NSPoint(x: r.maxX - 280, y: r.minY + 220))
        }
        observeMove(win)
        self.window = win
    }

    private func observeMove(_ win: NSWindow) {
        // Save frame mỗi khi user drag — Notification thay vì delegate để khỏi
        // alloc thêm class chỉ để conform NSWindowDelegate.
        NotificationCenter.default.addObserver(
            forName: NSWindow.didMoveNotification, object: win, queue: .main
        ) { [weak self] note in
            guard let w = note.object as? NSWindow else { return }
            Task { @MainActor in
                self?.persistFrame(w.frame)
            }
        }
    }

    private func persistFrame(_ frame: NSRect) {
        UserDefaults.standard.set(NSStringFromRect(frame), forKey: frameKey)
    }
}
