import Foundation
import CryptoKit

public struct SourceFileManifest: Codable, Sendable, Equatable {
    public let path: String
    public let byteCount: Int
    public let sha256: String?
    public let modifiedAt: Date?
    public let malformedRecordCount: Int
    public let readable: Bool
    public let changedDuringRead: Bool

    public static func inspect(_ url: URL) -> SourceFileManifest {
        let before = try? url.resourceValues(forKeys: [.fileSizeKey, .contentModificationDateKey])
        var digest = SHA256()
        var bytes = 0
        var malformed = 0
        var buffer = Data()
        var readable = false
        if let handle = try? FileHandle(forReadingFrom: url) {
            defer { try? handle.close() }
            do {
                while let data = try handle.read(upToCount: 65_536), !data.isEmpty {
                    bytes += data.count; digest.update(data: data); buffer.append(data)
                    while let newline = buffer.firstIndex(of: 10) {
                        let line = buffer[..<newline]
                        if !line.isEmpty, (try? JSONSerialization.jsonObject(with: line)) == nil { malformed += 1 }
                        buffer.removeSubrange(...newline)
                    }
                    // Source logs are untrusted. Bound record memory, keeping the
                    // hash exact; exceptionally large records are not report evidence.
                    if buffer.count > 16 * 1_024 * 1_024 { malformed += 1; buffer.removeAll(keepingCapacity: true) }
                }
                if !buffer.isEmpty, (try? JSONSerialization.jsonObject(with: buffer)) == nil { malformed += 1 }
                readable = true
            } catch { readable = false }
        }
        let after = try? url.resourceValues(forKeys: [.fileSizeKey, .contentModificationDateKey])
        return SourceFileManifest(path: url.path, byteCount: bytes,
                                  sha256: readable ? digest.finalize().map { String(format: "%02x", $0) }.joined() : nil,
                                  modifiedAt: before?.contentModificationDate, malformedRecordCount: malformed,
                                  readable: readable,
                                  changedDuringRead: before?.fileSize != after?.fileSize
                                    || before?.contentModificationDate != after?.contentModificationDate)
    }
}

public struct SourceRootManifest: Codable, Sendable, Equatable {
    public let path: String
    public let exists: Bool
    public let readable: Bool
    public init(path: String) {
        self.path = path
        exists = FileManager.default.fileExists(atPath: path)
        readable = FileManager.default.isReadableFile(atPath: path)
    }
}
