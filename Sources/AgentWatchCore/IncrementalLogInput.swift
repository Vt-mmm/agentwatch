import Foundation
import CryptoKit
import Darwin

/// A stable stat plus two small guards detects replacement, truncation and
/// common rewrites without rereading the consumed history on append. Evidence
/// exports deliberately use the original, full readers instead.
struct LogFileStamp: Codable, Equatable, Sendable {
    let size: UInt64
    let modified: Date
    let born: Date
    let changeSeconds: Int64
    let changeNanoseconds: Int64
    let inode: UInt64
    let device: UInt64

    static func read(_ url: URL) -> Self? {
        var info = stat()
        guard url.path.withCString({ Darwin.fstatat(AT_FDCWD, $0, &info, 0) }) == 0,
              info.st_size >= 0, info.st_mode & S_IFMT == S_IFREG else { return nil }
        func date(_ time: timespec) -> Date {
            Date(timeIntervalSince1970: Double(time.tv_sec) + Double(time.tv_nsec) / 1_000_000_000)
        }
        return Self(size: UInt64(info.st_size), modified: date(info.st_mtimespec),
                    born: date(info.st_birthtimespec),
                    changeSeconds: Int64(info.st_ctimespec.tv_sec),
                    changeNanoseconds: Int64(info.st_ctimespec.tv_nsec),
                    inode: UInt64(info.st_ino), device: UInt64(bitPattern: Int64(info.st_dev)))
    }
}

struct LogCheckpoint: Codable, Sendable {
    let offset: UInt64
    let state: Data
    let headHash: String
    let boundaryHash: String

    static func hashes(_ url: URL, offset: UInt64) -> (String, String)? {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? handle.close() }
        do {
            let count = Int(min(offset, 4096))
            let head = try handle.read(upToCount: count) ?? Data()
            try handle.seek(toOffset: offset - UInt64(count))
            let tail = try handle.read(upToCount: count) ?? Data()
            guard head.count == count, tail.count == count else { return nil }
            return (digest(head), digest(tail))
        } catch { return nil }
    }

    private static func digest(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }
}

/// Confined to one parser invocation. The saved state stops BEFORE an
/// unterminated final line, so completing that line cannot double count usage.
final class IncrementalLogInput {
    let file: URL
    let stamp: LogFileStamp
    private var prior: LogCheckpoint?
    private(set) var checkpoint: LogCheckpoint?
    private(set) var bytesRead: UInt64 = 0
    private(set) var resumed = false
    private(set) var succeeded = false
    private(set) var firstTimestamp: Date?
    private(set) var lastTimestamp: Date?

    init(file: URL, stamp: LogFileStamp, previous: CachedLogFile?) {
        self.file = file; self.stamp = stamp
        if let previous, let checkpoint = previous.checkpoint,
           stamp.inode == previous.stamp.inode, stamp.device == previous.stamp.device,
           stamp.born == previous.stamp.born,
           stamp.size > previous.stamp.size, checkpoint.offset <= previous.stamp.size,
           let hashes = LogCheckpoint.hashes(file, offset: checkpoint.offset),
           hashes.0 == checkpoint.headHash, hashes.1 == checkpoint.boundaryHash {
            prior = checkpoint
            firstTimestamp = previous.firstTimestamp
            lastTimestamp = previous.lastTimestamp
        }
    }

    func observe(_ timestamp: Date?) {
        guard let timestamp else { return }
        firstTimestamp = min(firstTimestamp ?? timestamp, timestamp)
        lastTimestamp = max(lastTimestamp ?? timestamp, timestamp)
    }

    func restore<T: Decodable>(_ type: T.Type) -> T? {
        guard let prior else { return nil }
        guard let state = try? PropertyListDecoder().decode(type, from: prior.state) else {
            self.prior = nil
            return nil
        }
        resumed = true
        return state
    }

    func read(state: () -> Data?, line: (Data) -> Void) {
        guard let handle = try? FileHandle(forReadingFrom: file) else { return }
        defer { try? handle.close() }
        var offset = resumed ? prior?.offset ?? 0 : 0
        var completeOffset = offset
        var pending = Data()
        do {
            try handle.seek(toOffset: offset)
            while offset < stamp.size, !Task.isCancelled {
                let count = Int(min(256 * 1024, stamp.size - offset))
                guard let chunk = try handle.read(upToCount: count), !chunk.isEmpty else { return }
                offset += UInt64(chunk.count); bytesRead += UInt64(chunk.count)
                // Search only new bytes once, even for multi-MB JSONL records.
                autoreleasepool {
                    chunk.withUnsafeBytes { raw in
                        guard let base = raw.baseAddress else { return }
                        var index = 0
                        while index < raw.count, !Task.isCancelled {
                            let start = base.advanced(by: index)
                            guard let newline = memchr(start, 10, raw.count - index) else {
                                pending.append(start.assumingMemoryBound(to: UInt8.self), count: raw.count - index)
                                break
                            }
                            let length = start.distance(to: UnsafeRawPointer(newline))
                            pending.append(start.assumingMemoryBound(to: UInt8.self), count: length)
                            line(pending)
                            pending = Data()
                            index += length + 1
                            completeOffset = offset - UInt64(raw.count - index)
                        }
                    }
                }
            }
            guard !Task.isCancelled, offset == stamp.size else { return }
            // Encoding before the tail retains the pre-tail dedupe/counter state.
            if let data = state(), let hashes = LogCheckpoint.hashes(file, offset: completeOffset) {
                checkpoint = LogCheckpoint(offset: completeOffset, state: data,
                                           headHash: hashes.0, boundaryHash: hashes.1)
            }
            if !pending.isEmpty { line(pending) }
            succeeded = LogFileStamp.read(file) == stamp
            if !succeeded { checkpoint = nil }
        } catch { checkpoint = nil }
    }

    static func encode<T: Encodable>(_ value: T) -> Data? {
        let encoder = PropertyListEncoder()
        encoder.outputFormat = .binary
        return try? encoder.encode(value)
    }
}
