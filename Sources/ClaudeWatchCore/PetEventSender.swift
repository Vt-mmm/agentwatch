// PetEventSender — gửi PetEvent tới app qua Unix domain socket.
// Dùng POSIX socket API trực tiếp (Darwin) để tránh Foundation overhead và
// cho phép compile trong CLI target không có AppKit.
//
// Fire-and-forget: nếu socket không tồn tại hoặc send thất bại thì im lặng.
// KHÔNG block Claude Code hook — timeout 100ms qua SO_SNDTIMEO.

import Foundation
#if canImport(Darwin)
import Darwin
#endif

public enum PetEventSender {
    /// Gửi một PetEvent tới socket. Silent fail nếu app không chạy.
    /// Safe to call từ bất kỳ thread nào (không dùng shared state).
    public static func send(_ event: PetEvent) {
        guard let payload = try? event.toLine() else { return }
        let sockPath = PetEvent.socketPath

        // Kiểm tra socket file tồn tại trước khi tạo descriptor.
        guard FileManager.default.fileExists(atPath: sockPath) else { return }

        // socket(AF_UNIX, SOCK_STREAM, 0)
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { return }
        defer { close(fd) }

        // SO_SNDTIMEO = 100ms — không block Claude Code nếu app treo.
        var tv = timeval(tv_sec: 0, tv_usec: 100_000)
        setsockopt(fd, SOL_SOCKET, SO_SNDTIMEO, &tv, socklen_t(MemoryLayout<timeval>.size))

        // Xây sockaddr_un với path.
        var addr = sockaddr_un()
        addr.sun_family = sa_family_t(AF_UNIX)

        // Copy path bytes vào sun_path (fixed-size tuple, max 104 bytes trên macOS).
        let pathBytes = sockPath.utf8CString
        guard pathBytes.count <= MemoryLayout.size(ofValue: addr.sun_path) else { return }
        withUnsafeMutableBytes(of: &addr.sun_path) { ptr in
            pathBytes.withUnsafeBytes { src in
                ptr.copyMemory(from: UnsafeRawBufferPointer(
                    start: src.baseAddress,
                    count: min(src.count, ptr.count)))
            }
        }

        // connect
        let connectResult = withUnsafePointer(to: &addr) { ptr in
            ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { sockPtr in
                Darwin.connect(fd, sockPtr, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        guard connectResult == 0 else { return }

        // write — gửi toàn bộ payload.
        payload.withUnsafeBytes { buf in
            guard let base = buf.baseAddress else { return }
            _ = Darwin.write(fd, base, buf.count)
        }
    }
}
