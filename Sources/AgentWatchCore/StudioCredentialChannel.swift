import Foundation
import Darwin

/// Same-user hand-off of the saved Studio key from the running app to the
/// `agentwatch credential` helper that Claude Code, Codex and Pi call.
///
/// Updating an ad-hoc signed executable can require renewed Keychain approval.
/// The app can request that approval through its UI; the noninteractive helper
/// cannot. It asks the app first, then tries its own noninteractive Keychain read.
///
/// Boundary: the socket file is 0600 and the server checks the peer's user id.
/// Any process of the same user could already run the helper, so this adds no
/// new reader. Only saved, unblocked direct profiles are served. This is not
/// the managed broker and does not isolate agent tools running as this user.
public enum StudioCredentialChannel {
    public static var socketPath: String {
        AgentWatchIdentity.applicationSupportDirectory().path + "/studio-credential.sock"
    }

    /// The key for `profileID` from the running app, or nil when the app is not
    /// running, refuses, or does not answer within `timeout`.
    public static func request(profileID: String, path: String = socketPath, timeout: TimeInterval = 3) -> String? {
        guard !profileID.isEmpty, profileID.utf8.count <= 128,
              profileID.utf8.allSatisfy({ (48...57).contains($0) || (97...122).contains($0) || (65...90).contains($0) || $0 == 45 }),
              var address = unixAddress(path) else { return nil }
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { return nil }
        defer { close(fd) }
        configure(fd, timeout: timeout)
        let connected = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { connect(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) }
        }
        guard connected == 0, send(fd, "credential \(profileID)\n"),
              let line = readLine(fd, limit: 4200), line.hasPrefix("ok ") else { return nil }
        let key = String(line.dropFirst(3))
        return StudioClient.validKey(key) ? key : nil
    }

    static func unixAddress(_ path: String) -> sockaddr_un? {
        var address = sockaddr_un()
        address.sun_family = sa_family_t(AF_UNIX)
        let bytes = Array(path.utf8CString)
        guard bytes.count <= MemoryLayout.size(ofValue: address.sun_path) else { return nil }
        withUnsafeMutableBytes(of: &address.sun_path) { target in
            bytes.withUnsafeBytes { target.copyMemory(from: $0) }
        }
        return address
    }

    static func configure(_ fd: Int32, timeout: TimeInterval) {
        var interval = timeval(tv_sec: Int(timeout), tv_usec: Int32((timeout - timeout.rounded(.down)) * 1_000_000))
        setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &interval, socklen_t(MemoryLayout<timeval>.size))
        setsockopt(fd, SOL_SOCKET, SO_SNDTIMEO, &interval, socklen_t(MemoryLayout<timeval>.size))
        var one: Int32 = 1
        setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &one, socklen_t(MemoryLayout<Int32>.size))
    }

    static func send(_ fd: Int32, _ text: String) -> Bool {
        let bytes = Array(text.utf8)
        var sent = 0
        while sent < bytes.count {
            let n = bytes[sent...].withUnsafeBytes { write(fd, $0.baseAddress, $0.count) }
            if n <= 0 { return false }
            sent += n
        }
        return true
    }

    /// One newline-terminated line, at most `limit` bytes; nil on timeout,
    /// EOF before a newline, or an oversized line.
    static func readLine(_ fd: Int32, limit: Int) -> String? {
        var data = [UInt8]()
        var byte: UInt8 = 0
        while data.count <= limit {
            let n = read(fd, &byte, 1)
            if n <= 0 { return nil }
            if byte == 10 { return String(bytes: data, encoding: .utf8) }
            data.append(byte)
        }
        return nil
    }
}

/// Serves `StudioCredentialChannel` requests inside the app. `provider` returns
/// the saved key for a profile id, or nil to refuse; it runs off the main thread.
public final class StudioCredentialServer: @unchecked Sendable {
    private let path: String
    private let provider: @Sendable (String) -> String?
    private let queue = DispatchQueue(label: "com.vtamm.agentwatch.studio-credential", qos: .userInitiated)
    private let lock = NSLock()
    private var listener: Int32 = -1
    private var lease: StudioSocketLease?
    private var generation = UUID()

    public init(path: String = StudioCredentialChannel.socketPath, provider: @escaping @Sendable (String) -> String?) {
        self.path = path
        self.provider = provider
    }

    /// Idempotent. Returns false when the socket cannot be created.
    @discardableResult public func start() -> Bool {
        lock.lock(); defer { lock.unlock() }
        guard listener < 0 else { return true }
        guard var address = StudioCredentialChannel.unixAddress(path) else { return false }
        guard let ownership = StudioSocketLease.acquire(path: path) else { return false }
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { ownership.release(); return false }
        guard fcntl(fd, F_SETFD, FD_CLOEXEC) == 0 else { close(fd); ownership.release(); return false }
        let bound = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) }
        }
        guard bound == 0 else { close(fd); ownership.release(); return false }
        ownership.recordSocket()
        guard chmod(path, 0o600) == 0, listen(fd, 8) == 0 else {
            close(fd); ownership.release()
            return false
        }
        // The accept loop owns a separate descriptor. stop()/start() cannot
        // recycle its descriptor into a different listener before it exits.
        let acceptFD = dup(fd)
        guard acceptFD >= 0, fcntl(acceptFD, F_SETFD, FD_CLOEXEC) == 0 else {
            if acceptFD >= 0 { close(acceptFD) }
            close(fd); ownership.release(); return false
        }
        generation = UUID()
        let currentGeneration = generation
        lease = ownership
        listener = fd
        queue.async { [weak self] in
            defer { close(acceptFD) }
            while true {
                let client = accept(acceptFD, nil, nil)
                if client < 0 { if errno == EINTR { continue }; return }
                guard fcntl(client, F_SETFD, FD_CLOEXEC) == 0,
                      let self, self.isActive(currentGeneration) else { close(client); return }
                self.handle(client, generation: currentGeneration)
            }
        }
        return true
    }

    public func stop() {
        lock.lock(); defer { lock.unlock() }
        guard listener >= 0 else { return }
        shutdown(listener, SHUT_RDWR)
        close(listener)
        listener = -1
        generation = UUID()
        lease?.release()
        lease = nil
    }

    deinit { stop() }

    private func isActive(_ expected: UUID) -> Bool {
        lock.lock(); defer { lock.unlock() }
        return listener >= 0 && generation == expected
    }

    private func handle(_ client: Int32, generation: UUID) {
        defer { close(client) }
        var uid = uid_t(), gid = gid_t()
        guard getpeereid(client, &uid, &gid) == 0, uid == getuid() else { return }
        StudioCredentialChannel.configure(client, timeout: 2)
        guard let line = StudioCredentialChannel.readLine(client, limit: 256), line.hasPrefix("credential ") else { return }
        guard isActive(generation) else { return }
        let key = provider(String(line.dropFirst("credential ".count))).flatMap { StudioClient.validKey($0) ? $0 : nil }
        guard isActive(generation) else { return }
        _ = StudioCredentialChannel.send(client, key.map { "ok \($0)\n" } ?? "no\n")
    }
}

/// Cooperative process ownership; not authentication against another process
/// of the same user. The legacy direct-key channel still needs the managed
/// broker boundary before it can serve managed execution.
private final class StudioSocketLease {
    private let path: String
    private var fd: Int32
    private var socketIdentity: stat?

    private init(path: String, fd: Int32) { self.path = path; self.fd = fd }

    static func acquire(path: String) -> StudioSocketLease? {
        let parent = URL(fileURLWithPath: path).deletingLastPathComponent().resolvingSymlinksInPath().path
        var directory = stat()
        guard lstat(parent, &directory) == 0, directory.st_uid == getuid(),
              directory.st_mode & S_IFMT == S_IFDIR, directory.st_mode & 0o022 == 0 else { return nil }
        let lockPath = path + ".lock"
        let fd = open(lockPath, O_RDWR | O_CREAT | O_NOFOLLOW | O_CLOEXEC, 0o600)
        guard fd >= 0 else { return nil }
        var info = stat(), entry = stat()
        guard fstat(fd, &info) == 0, info.st_uid == getuid(), info.st_nlink == 1,
              info.st_mode & S_IFMT == S_IFREG, info.st_mode & 0o777 == 0o600,
              flock(fd, LOCK_EX | LOCK_NB) == 0,
              lstat(lockPath, &entry) == 0, sameObject(info, entry) else { close(fd); return nil }
        let ownership = StudioSocketLease(path: path, fd: fd)
        var socketInfo = stat()
        if lstat(path, &socketInfo) == 0 {
            guard socketInfo.st_uid == getuid(), socketInfo.st_mode & S_IFMT == S_IFSOCK,
                  isStale(path), matches(path, socketInfo), unlink(path) == 0 else {
                ownership.release(); return nil
            }
        } else if errno != ENOENT { ownership.release(); return nil }
        return ownership
    }

    // A live older app may not implement our lease. Refuse to replace it.
    private static func isStale(_ path: String) -> Bool {
        guard var address = StudioCredentialChannel.unixAddress(path) else { return false }
        let probe = socket(AF_UNIX, SOCK_STREAM, 0)
        guard probe >= 0 else { return false }
        defer { close(probe) }
        guard fcntl(probe, F_SETFD, FD_CLOEXEC) == 0,
              fcntl(probe, F_SETFL, O_NONBLOCK) == 0 else { return false }
        let result = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { connect(probe, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) }
        }
        return result < 0 && errno == ECONNREFUSED
    }

    func recordSocket() {
        var info = stat()
        if lstat(path, &info) == 0, info.st_uid == getuid(), info.st_mode & S_IFMT == S_IFSOCK { socketIdentity = info }
    }

    func release() {
        guard fd >= 0 else { return }
        if let socketIdentity, Self.matches(path, socketIdentity) { unlink(path) }
        socketIdentity = nil
        // Never unlink the lock file: contenders must keep using one inode.
        flock(fd, LOCK_UN); close(fd); fd = -1
    }

    private static func sameObject(_ a: stat, _ b: stat) -> Bool {
        a.st_dev == b.st_dev && a.st_ino == b.st_ino && a.st_uid == b.st_uid && a.st_mode & S_IFMT == b.st_mode & S_IFMT
    }

    private static func matches(_ path: String, _ expected: stat) -> Bool {
        var current = stat()
        return lstat(path, &current) == 0 && sameObject(current, expected)
    }

    deinit { release() }
}
