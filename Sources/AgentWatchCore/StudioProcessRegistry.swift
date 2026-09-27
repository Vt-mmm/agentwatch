import Foundation
import Darwin

public enum StudioProcessError: Error, Equatable, Sendable { case busy, invalidRegistry, unavailable, changedProcess, stopFailed }
public struct StudioManagedProcess: Codable, Identifiable, Equatable, Sendable {
    public let version: Int
    public let id: UUID
    public let connection: StudioProfile
    public let provider: StudioCLIProvider
    public let executable: String
    public let model: String
    public let pid: Int32
    public let uid: UInt32
    public let startSeconds, startMicroseconds: UInt64
    public let registeredAt: Date
}
public enum StudioProcessState: String, Sendable { case running, finished, unverified }
public struct StudioProcessEntry: Identifiable, Sendable {
    public let process: StudioManagedProcess
    public let state: StudioProcessState
    public var id: UUID { process.id }
}
public struct StudioProcessSnapshot: Sendable {
    public let entries: [StudioProcessEntry]
    public let incomplete: Bool
}

/// Registry metadata is private to this OS user. It is not a sandbox against
/// another program running as that same user. Never stores keys, argv or prompts.
public struct StudioProcessRegistry: Sendable {
    public let directory: URL
    public init(directory: URL = StudioCLIProfiles.directory) { self.directory = directory }
    private func root(_ connection: StudioProfile) -> URL { directory.appendingPathComponent(connection.id, isDirectory: true) }
    private func runs(_ connection: StudioProfile) -> URL { root(connection).appendingPathComponent("runs", isDirectory: true) }
    private func file(_ id: UUID, _ connection: StudioProfile) -> URL { runs(connection).appendingPathComponent(id.uuidString.lowercased() + ".json") }

    /// Hold only for final credential validation/registration/exec or disconnect.
    /// The close-on-exec descriptor releases the lock after successful execve.
    /// Never wait on the main UI thread or silently bypass an occupied lock.
    public func withLaunchLock<T>(connection: StudioProfile, _ body: () throws -> T) throws -> T {
        for path in [directory, root(connection), runs(connection)] { try StudioCLIProfiles.privateDirectory(path) }
        let lock = root(connection).appendingPathComponent("run.lock")
        try StudioLogRegistry.requireUnredirected(lock)
        let fd = open(lock.path, O_CREAT | O_RDWR | O_CLOEXEC | O_NOFOLLOW, 0o600)
        guard fd >= 0 else { throw StudioProcessError.invalidRegistry }
        defer { close(fd) }
        var info = stat()
        guard fstat(fd, &info) == 0, info.st_uid == getuid(), info.st_mode & S_IFMT == S_IFREG,
              info.st_nlink == 1, info.st_mode & 0o077 == 0 else { throw StudioProcessError.invalidRegistry }
        guard flock(fd, LOCK_EX | LOCK_NB) == 0 else { throw StudioProcessError.busy }
        defer { flock(fd, LOCK_UN) }
        return try body()
    }
    // Call under withLaunchLock. The internal PID argument is for isolated
    // fixture children; production always registers the launcher itself.
    func register(plan: StudioCLILaunchPlan, pid: Int32 = getpid()) throws -> StudioManagedProcess {
        guard let info = StudioProcessControl.info(pid), info.pbi_uid == getuid(), info.pbi_ruid == getuid() else { throw StudioProcessError.unavailable }
        let existing = snapshot(connection: plan.profile.connection)
        guard !existing.incomplete else { throw StudioProcessError.invalidRegistry }
        for entry in existing.entries where entry.state == .finished { try remove(entry.process) }
        guard existing.entries.filter({ $0.state != .finished }).count < 128 else { throw StudioProcessError.invalidRegistry }
        let record = StudioManagedProcess(version: 1, id: UUID(), connection: plan.profile.connection, provider: plan.profile.provider,
                                          executable: plan.executable.url.path, model: plan.model.id, pid: pid, uid: getuid(),
                                          startSeconds: info.pbi_start_tvsec, startMicroseconds: info.pbi_start_tvusec, registeredAt: Date())
        let path = file(record.id, record.connection)
        try JSONEncoder().encode(record).write(to: path, options: [.withoutOverwriting])
        do { try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: path.path) }
        catch { try? FileManager.default.removeItem(at: path); throw error }
        return record
    }
    func remove(_ process: StudioManagedProcess) throws {
        let current = try read(id: process.id, connection: process.connection)
        guard current == process else { throw StudioProcessError.invalidRegistry }
        try FileManager.default.removeItem(at: file(process.id, process.connection))
    }
    private func read(id: UUID, connection: StudioProfile) throws -> StudioManagedProcess {
        let path = file(id, connection)
        try StudioLogRegistry.requireUnredirected(path)
        let info = try FileManager.default.attributesOfItem(atPath: path.path)
        guard info[.type] as? FileAttributeType == .typeRegular, (info[.ownerAccountID] as? NSNumber)?.uint32Value == getuid(),
              let size = info[.size] as? NSNumber, size.intValue <= 8192,
              let mode = info[.posixPermissions] as? NSNumber, mode.intValue & 0o077 == 0,
              (info[.referenceCount] as? NSNumber)?.intValue == 1 else { throw StudioProcessError.invalidRegistry }
        let record = try JSONDecoder().decode(StudioManagedProcess.self, from: Data(contentsOf: path))
        guard record.version == 1, record.id == id, record.connection == connection, record.uid == getuid(), record.pid > 1,
              record.startSeconds > 0, record.startMicroseconds < 1_000_000, record.executable.hasPrefix("/"),
              !record.executable.contains("\0"), record.executable.utf8.count < 4096,
              !record.model.isEmpty, record.model.utf8.count <= 160 else { throw StudioProcessError.invalidRegistry }
        return record
    }
    public func snapshot(connection: StudioProfile) -> StudioProcessSnapshot {
        do {
            let folder = runs(connection)
            try StudioLogRegistry.requireUnredirected(folder)
            guard FileManager.default.fileExists(atPath: folder.path) else { return StudioProcessSnapshot(entries: [], incomplete: false) }
            let files = try FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil)
            guard files.count <= 256 else { return StudioProcessSnapshot(entries: [], incomplete: true) }
            var entries: [StudioProcessEntry] = [], incomplete = false
            for path in files {
                guard path.pathExtension == "json", let id = UUID(uuidString: path.deletingPathExtension().lastPathComponent) else { incomplete = true; continue }
                do {
                    let record = try read(id: id, connection: connection)
                    entries.append(StudioProcessEntry(process: record, state: StudioProcessControl.state(record)))
                } catch { incomplete = true }
            }
            return StudioProcessSnapshot(entries: entries.sorted { $0.process.registeredAt > $1.process.registeredAt }, incomplete: incomplete)
        } catch { return StudioProcessSnapshot(entries: [], incomplete: true) }
    }
    /// Only signals a re-read registered main CLI process, through macOS's
    /// audit-token/idversion API. No PID-only, process-name or process-group kill.
    /// SIGTERM may be ignored; return the observed result, never claim closure.
    public func stop(_ process: StudioManagedProcess) async throws -> StudioProcessState {
        guard try read(id: process.id, connection: process.connection) == process else { throw StudioProcessError.invalidRegistry }
        let state = StudioProcessControl.state(process)
        if state == .finished { return state }
        guard state == .running else { throw StudioProcessError.changedProcess }
        var token = try StudioProcessControl.token(process)
        guard StudioProcessControl.signal(&token, SIGTERM) == 0 else { throw StudioProcessError.stopFailed }
        for _ in 0..<20 {
            try await Task.sleep(for: .milliseconds(100))
            let current = StudioProcessControl.state(process)
            if current != .running { return current }
        }
        return .running
    }
}

enum StudioProcessControl {
    static func info(_ pid: Int32) -> proc_bsdinfo? {
        guard pid > 1 else { return nil }
        var info = proc_bsdinfo()
        let size = MemoryLayout<proc_bsdinfo>.size
        errno = 0
        guard proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, &info, Int32(size)) == size else { return nil }
        return info
    }
    static func state(_ process: StudioManagedProcess) -> StudioProcessState {
        guard let info = info(process.pid) else { return errno == ESRCH ? .finished : .unverified }
        if info.pbi_start_tvsec != process.startSeconds || info.pbi_start_tvusec != process.startMicroseconds || info.pbi_status == 5 { return .finished } // SZOMB
        return (try? token(process)) == nil ? .unverified : .running
    }
    static func token(_ process: StudioManagedProcess) throws -> audit_token_t {
        var port: mach_port_t = 0
        guard task_name_for_pid(mach_task_self_, process.pid, &port) == KERN_SUCCESS, port != 0 else { throw StudioProcessError.unavailable }
        defer { mach_port_deallocate(mach_task_self_, port) }
        var token = audit_token_t(), count = mach_msg_type_number_t(MemoryLayout<audit_token_t>.size / MemoryLayout<integer_t>.size)
        let result = withUnsafeMutablePointer(to: &token) { pointer in
            pointer.withMemoryRebound(to: integer_t.self, capacity: Int(count)) { task_info(port, task_flavor_t(TASK_AUDIT_TOKEN), $0, &count) }
        }
        guard result == KERN_SUCCESS, token.val.5 == UInt32(process.pid), let info = info(process.pid),
              info.pbi_uid == process.uid, info.pbi_ruid == process.uid, info.pbi_uid == getuid(),
              info.pbi_start_tvsec == process.startSeconds, info.pbi_start_tvusec == process.startMicroseconds else { throw StudioProcessError.changedProcess }
        var path = [CChar](repeating: 0, count: 4096)
        guard proc_pidpath_audittoken(&token, &path, UInt32(path.count)) > 0,
              String(cString: path) == process.executable else { throw StudioProcessError.changedProcess }
        return token
    }
    static func signal(_ token: inout audit_token_t, _ signal: Int32) -> Int32 {
        // Older runtimes without this API fail closed instead of falling back
        // to kill(pid). No optional/private binary is installed on the host.
        guard let library = dlopen("/usr/lib/libproc.dylib", RTLD_NOW | RTLD_LOCAL) else { return ENOTSUP }
        defer { dlclose(library) }
        guard let symbol = dlsym(library, "proc_signal_with_audittoken") else { return ENOTSUP }
        typealias Signal = @convention(c) (UnsafeMutablePointer<audit_token_t>?, Int32) -> Int32
        return unsafeBitCast(symbol, to: Signal.self)(&token, signal)
    }
}
