// PetSocketServer — Unix domain socket server chạy trong app.
// Nhận PetEvent JSON từ CLI hook, dispatch lên MainActor để cập nhật
// FloatingPetController (state + talk bubble).
//
// Lifecycle: start() trong ClaudeWatchMacApp.init, stop() khi app terminate.
// Accept loop chạy trên background DispatchQueue để không block MainActor.

import Foundation
import AppKit
import Observation
import ClaudeWatchCore

@Observable
@MainActor
final class PetSocketServer {
    /// Số connection đang pending tối đa.
    private let backlog: Int32 = 4

    /// File descriptor của listening socket. -1 = chưa start.
    private var listenFd: Int32 = -1

    /// Background queue xử lý accept + read loop.
    private let queue = DispatchQueue(label: "com.vtamm.claudewatch.pet-socket",
                                      qos: .utility)

    /// Weak ref để cập nhật pet. Set sau khi attach.
    weak var petController: FloatingPetController?

    /// Variant counter để rotate talk lines.
    private var talkVariant: Int = 0

    // MARK: - Public API

    /// Bắt đầu lắng nghe. Gọi lại idempotent (stop cũ trước khi start mới).
    func start() {
        guard listenFd < 0 else { return }

        let sockPath = PetEvent.socketPath

        // Mở socket AF_UNIX SOCK_STREAM.
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else {
            logError("socket() failed: \(errno)")
            return
        }

        // Unlink stale socket file (app crash trước đó có thể để lại).
        unlink(sockPath)

        // Bind.
        var addr = sockaddr_un()
        addr.sun_family = sa_family_t(AF_UNIX)
        let pathBytes = sockPath.utf8CString
        guard pathBytes.count <= MemoryLayout.size(ofValue: addr.sun_path) else {
            close(fd)
            logError("Socket path too long: \(sockPath)")
            return
        }
        withUnsafeMutableBytes(of: &addr.sun_path) { ptr in
            pathBytes.withUnsafeBytes { src in
                ptr.copyMemory(from: UnsafeRawBufferPointer(
                    start: src.baseAddress,
                    count: min(src.count, ptr.count)))
            }
        }

        let bindResult = withUnsafePointer(to: &addr) { ptr in
            ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { sockPtr in
                bind(fd, sockPtr, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        guard bindResult == 0 else {
            close(fd)
            logError("bind() failed: \(errno)")
            return
        }

        // Listen.
        guard listen(fd, backlog) == 0 else {
            close(fd)
            logError("listen() failed: \(errno)")
            return
        }

        listenFd = fd
        startAcceptLoop(fd: fd)
    }

    /// Dừng server: đóng socket + unlink path.
    func stop() {
        guard listenFd >= 0 else { return }
        let fd = listenFd
        listenFd = -1
        close(fd)
        unlink(PetEvent.socketPath)
    }

    // MARK: - Accept loop (background)

    private func startAcceptLoop(fd: Int32) {
        queue.async { [weak self] in
            while true {
                let clientFd = accept(fd, nil, nil)
                guard clientFd >= 0 else {
                    // fd đã close (stop() gọi) → thoát loop.
                    return
                }
                self?.handleClient(clientFd)
            }
        }
    }

    /// Đọc newline-delimited JSON từ client, decode PetEvent, dispatch lên MainActor.
    private func handleClient(_ fd: Int32) {
        defer { close(fd) }

        var buffer = Data()
        var chunk = [UInt8](repeating: 0, count: 4096)

        while true {
            let n = chunk.withUnsafeMutableBytes { ptr in
                guard let base = ptr.baseAddress else { return -1 }
                return read(fd, base, ptr.count)
            }
            if n <= 0 { break }
            buffer.append(contentsOf: chunk[0..<n])
            // Tìm và xử lý từng dòng hoàn chỉnh (newline-delimited JSON).
            while let newlineIdx = buffer.firstIndex(of: 0x0A) {
                let lineData = buffer[buffer.startIndex..<newlineIdx]
                buffer = buffer[buffer.index(after: newlineIdx)...]
                if let event = try? PetEvent.jsonDecoder.decode(PetEvent.self, from: lineData) {
                    let captured = event
                    DispatchQueue.main.async { [weak self] in
                        self?.handle(event: captured)
                    }
                }
            }
        }
        // Flush còn lại sau EOF nếu không có trailing newline.
        if !buffer.isEmpty,
           let event = try? PetEvent.jsonDecoder.decode(PetEvent.self, from: buffer) {
            let captured = event
            DispatchQueue.main.async { [weak self] in
                self?.handle(event: captured)
            }
        }
    }

    // MARK: - Event → pet update (MainActor)

    @MainActor
    private func handle(event: PetEvent) {
        guard let pet = petController else { return }

        talkVariant += 1
        let v = talkVariant

        switch event.kind {
        case .sessionStart:
            pet.state = .happy
            let talk = PetTalkOracle.line(for: .startup, variant: v)
            pet.say(talk, dismissAfter: 6)

        case .stop:
            pet.state = .excited
            let talk = PetTalkOracle.line(for: .taskDone(durationSec: 0), variant: v)
            pet.say(talk, dismissAfter: 8)

        case .preCompact:
            // state override .sleepy cho pre-compact — thông báo qua idle trigger.
            pet.state = .sleepy
            let talk = PetTalkOracle.line(for: .idle(minutesIdle: 0), variant: v)
            pet.say(talk, dismissAfter: 5)

        case .userPrompt:
            pet.state = .happy
            let talk = PetTalkOracle.line(for: .startup, variant: v)
            pet.say(talk, dismissAfter: 4)

        case .postToolUse:
            // Silent bounce — chỉ cập nhật state, không show talk bubble.
            pet.state = .excited

        case .subagentStop:
            pet.state = .happy
            let talk = PetTalkOracle.line(for: .subagentSpawned(total: 1), variant: v)
            pet.say(talk, dismissAfter: 5)
        }
    }

    // MARK: - Logging

    private func logError(_ msg: String) {
        // Debug only — không crash, không alert user.
        #if DEBUG
        print("[PetSocketServer] \(msg)")
        #endif
    }
}
