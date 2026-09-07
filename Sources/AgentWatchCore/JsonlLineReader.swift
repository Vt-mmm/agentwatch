import Foundation
import Darwin

enum JsonlLineReader {
    static func forEachLineData(at url: URL, _ body: (Data) -> Void) {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return }
        defer { try? handle.close() }
        var pending = Data()
        // Search only new bytes. Repeatedly searching a growing multi-MB image
        // record from its start made the old reader quadratic in line length.
        while !Task.isCancelled {
            let chunk = (try? handle.read(upToCount: 256 * 1024)) ?? Data()
            if chunk.isEmpty { break }
            autoreleasepool {
                chunk.withUnsafeBytes { raw in
                    guard let base = raw.baseAddress else { return }
                    var offset = 0
                    while offset < raw.count, !Task.isCancelled {
                        let start = base.advanced(by: offset)
                        guard let newline = memchr(start, 10, raw.count - offset) else {
                            pending.append(start.assumingMemoryBound(to: UInt8.self), count: raw.count - offset)
                            break
                        }
                        let length = start.distance(to: UnsafeRawPointer(newline))
                        if pending.isEmpty {
                            if length > 0 { body(Data(bytes: start, count: length)) }
                        } else {
                            pending.append(start.assumingMemoryBound(to: UInt8.self), count: length)
                            body(pending)
                            pending = Data()
                        }
                        offset += length + 1
                    }
                }
            }
        }
        if !pending.isEmpty, !Task.isCancelled { body(pending) }
    }
}
