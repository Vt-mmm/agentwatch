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
    /// didSet persists tới UserDefaults + syncs NSWindow visibility.
    var isVisible: Bool = false {
        didSet {
            UserDefaults.standard.set(isVisible, forKey: "FloatingPetController.visible")
            syncWindow()
        }
    }

    /// PetState hiện tại — caller cập nhật từ CoachingDataStore tick.
    var state: PetState = .happy { didSet { refresh() } }

    /// Talk bubble — set non-nil để pet "nói", tự nil sau dismissAfterSec.
    var talk: PetTalk? = nil { didSet { refresh() } }

    /// Character sprite name (char00..char26). Caller sync từ SpriteStore.
    var characterName: String = "char01" { didSet { refresh() } }

    /// Level hiện tại của pet đang active — sync từ PetCollectionStore.
    /// Default 1 cho lần đầu hoặc khi chưa có dữ liệu.
    var level: Int = 1 { didSet { refresh() } }

    private var window: NSWindow?
    private var dismissTask: Task<Void, Never>?
    private let frameKey = "FloatingPetController.frame"

    init() {
        // Restore từ UserDefaults — default = true vì floating pet giờ có mục
        // đích thực sự (nhận event từ socket daemon). User có thể tắt từ Settings.
        isVisible = UserDefaults.standard.object(forKey: "FloatingPetController.visible")
            .flatMap { $0 as? Bool } ?? true
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
                                         characterName: characterName, level: level)
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
                                                            characterName: characterName, level: level))
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

struct FloatingUsageSnapshot: Sendable, Equatable {
    var activeSessions: Int = 0
    var totalTokens: Int = 0
    var reasoningTokens: Int = 0
    var totalCost: Double = 0
    var toolCalls: Int = 0
    var models: String = "-"
    var thinkingLevel: String = "-"
    var piNamedSessions: Int = 0
    var piTotalSessions: Int = 0
    var latestTask: String = "No active task"
    var updatedAt: Date = Date()

    var hasActivity: Bool { activeSessions > 0 }
}

@Observable
@MainActor
final class FloatingUsageSidebarController {
    var isVisible: Bool = false {
        didSet {
            UserDefaults.standard.set(isVisible, forKey: "FloatingUsageSidebarController.visible")
            syncWindow()
        }
    }

    var snapshot = FloatingUsageSnapshot() { didSet { refresh() } }

    private var window: NSWindow?
    private let frameKey = "FloatingUsageSidebarController.frame"

    init() {
        isVisible = UserDefaults.standard.object(forKey: "FloatingUsageSidebarController.visible")
            .flatMap { $0 as? Bool } ?? true
    }

    func update(claude: SessionStats?,
                codex: CodexLiveSnapshot,
                piAgent: PiAgentLiveSnapshot) {
        let activeSessions = (claude == nil ? 0 : 1) + codex.sessionCount + piAgent.sessionCount
        let totalTokens = (claude?.totalTokens ?? 0) + codex.totalTokens + piAgent.totalTokens
        let reasoningTokens = (claude?.reasoningTokens ?? 0) + piAgent.totalReasoningTokens
        let totalCost = (claude?.cost ?? 0) + codex.totalCost + piAgent.totalCost
        let toolCalls = (claude?.toolCalls ?? 0) + codex.totalToolCalls + piAgent.totalToolCalls
        let modelList = [
            claude?.model.isEmpty == false ? claude?.model : nil,
            codex.latestSession?.model,
            piAgent.latestSession?.model
        ]
        .compactMap { $0 }
        .filter { !$0.isEmpty }
        let thinking = [
            claude?.thinkingLevel,
            piAgent.latestSession?.thinkingLevel
        ]
        .compactMap { $0 }
        .filter { !$0.isEmpty }
        let latestTask = latestTaskTitle(claude: claude, codex: codex, piAgent: piAgent)

        snapshot = FloatingUsageSnapshot(
            activeSessions: activeSessions,
            totalTokens: totalTokens,
            reasoningTokens: reasoningTokens,
            totalCost: totalCost,
            toolCalls: toolCalls,
            models: compactList(modelList),
            thinkingLevel: compactList(thinking),
            piNamedSessions: piAgent.namedTaskCount,
            piTotalSessions: piAgent.sessionCount,
            latestTask: latestTask,
            updatedAt: Date()
        )
        syncWindow()
    }

    private func syncWindow() {
        if isVisible {
            if window == nil { createWindow() }
            refresh()
            window?.orderFront(nil)
        } else {
            window?.orderOut(nil)
        }
    }

    private func refresh() {
        guard let win = window,
              let host = win.contentView as? NSHostingView<FloatingUsageSidebarView> else { return }
        host.rootView = FloatingUsageSidebarView(snapshot: snapshot)
    }

    private func createWindow() {
        let initialSize = NSRect(x: 0, y: 0, width: 236, height: 318)
        let win = NSPanel(
            contentRect: initialSize,
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false)
        win.isOpaque = false
        win.backgroundColor = .clear
        win.hasShadow = true
        win.level = .floating
        win.isMovableByWindowBackground = true
        win.collectionBehavior = [.canJoinAllSpaces, .stationary, .fullScreenAuxiliary]
        win.ignoresMouseEvents = false
        win.hidesOnDeactivate = false

        let host = NSHostingView(rootView: FloatingUsageSidebarView(snapshot: snapshot))
        host.translatesAutoresizingMaskIntoConstraints = true
        host.autoresizingMask = [.width, .height]
        host.frame = win.contentView?.bounds ?? initialSize
        win.contentView = host

        if let saved = UserDefaults.standard.string(forKey: frameKey) {
            win.setFrame(NSRectFromString(saved), display: false)
        } else if let screen = NSScreen.main {
            let r = screen.visibleFrame
            win.setFrameTopLeftPoint(NSPoint(x: r.maxX - initialSize.width - 12,
                                             y: r.midY + initialSize.height / 2))
        }
        observeMove(win)
        self.window = win
    }

    private func observeMove(_ win: NSWindow) {
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

    private func latestTaskTitle(claude: SessionStats?,
                                 codex: CodexLiveSnapshot,
                                 piAgent: PiAgentLiveSnapshot) -> String {
        let claudeItem = claude.map {
            (title: ProjectPath.displayPath(for: $0.projectSlug), date: $0.mtime)
        }
        let codexItem = codex.latestSession.map {
            (title: $0.displayTitle, date: $0.lastTimestamp ?? .distantPast)
        }
        let piItem = piAgent.latestSession.map {
            (title: $0.displayTitle, date: $0.lastTimestamp ?? .distantPast)
        }
        return [claudeItem, codexItem, piItem]
            .compactMap { $0 }
            .sorted { $0.date > $1.date }
            .first?.title ?? "No active task"
    }

    private func compactList(_ values: [String]) -> String {
        let unique = Array(NSOrderedSet(array: values)).compactMap { $0 as? String }
        guard !unique.isEmpty else { return "-" }
        let joined = unique.prefix(2).joined(separator: ", ")
        return unique.count > 2 ? joined + " +" + String(unique.count - 2) : joined
    }
}
