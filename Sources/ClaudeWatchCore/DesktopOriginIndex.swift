// Phân biệt session nào trong ~/.claude/projects/ thực sự là CLI (terminal)
// vs Desktop Claude Code panel.
//
// Cả hai dùng chung runtime `claude-code` → ghi transcript vào cùng folder
// ~/.claude/projects/<slug>/<uuid>.jsonl. Khác biệt duy nhất là Desktop sẽ
// thêm 1 metadata file ở ~/Library/Application Support/Claude/claude-code-sessions/
// chứa `cliSessionId` trỏ về UUID transcript đó.
//
// Quy tắc phân loại:
//   - uuid IN index  → .desktop (Code panel run from Desktop app)
//   - uuid NOT in    → .cli      (terminal run)
//
// Index lazy-build 1 lần mỗi load: cost ~127 file × 1KB JSON ≈ 130ms.

import Foundation

public struct DesktopOriginIndex: Sendable {
    /// Set UUID transcript ở ~/.claude/projects/ có nguồn gốc Desktop.
    public let desktopSessionUuids: Set<String>

    public init(desktopSessionUuids: Set<String>) {
        self.desktopSessionUuids = desktopSessionUuids
    }

    public func classify(uuid: String) -> SessionSource {
        desktopSessionUuids.contains(uuid) ? .desktop : .cli
    }

    // MARK: - Cached load

    /// Trả index, reuse cache trong vòng `ttl` giây để tránh re-scan ~127 file
    /// metadata mỗi lần PromptHistory/SessionInventory được gọi. Coaching tab
    /// reload mỗi 5s → cache 60s đủ tươi.
    public static func shared(ttl: TimeInterval = 60) -> DesktopOriginIndex {
        cacheLock.lock(); defer { cacheLock.unlock() }
        let now = Date()
        if let last = lastLoaded, now.timeIntervalSince(last) < ttl,
           let cached = cachedIndex {
            return cached
        }
        let fresh = loadFromDisk()
        cachedIndex = fresh
        lastLoaded = now
        return fresh
    }

    nonisolated(unsafe) private static var cachedIndex: DesktopOriginIndex?
    nonisolated(unsafe) private static var lastLoaded: Date?
    nonisolated(unsafe) private static let cacheLock = NSLock()

    /// Quét toàn bộ ~/Library/Application Support/Claude/claude-code-sessions/
    /// để build index. Mỗi file local_*.json có field "cliSessionId" trỏ về
    /// UUID jsonl trong ~/.claude/projects/.
    public static func loadFromDisk() -> DesktopOriginIndex {
        let root = NSHomeDirectory()
            + "/Library/Application Support/Claude/claude-code-sessions"
        let fm = FileManager.default
        guard fm.fileExists(atPath: root),
              let enumerator = fm.enumerator(at: URL(fileURLWithPath: root),
                                              includingPropertiesForKeys: nil) else {
            return DesktopOriginIndex(desktopSessionUuids: [])
        }
        var uuids: Set<String> = []
        for case let url as URL in enumerator
            where url.pathExtension == "json"
                && url.lastPathComponent.hasPrefix("local_") {
            if let data = try? Data(contentsOf: url),
               let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
               let cliUuid = obj["cliSessionId"] as? String, !cliUuid.isEmpty {
                uuids.insert(cliUuid)
            }
        }
        return DesktopOriginIndex(desktopSessionUuids: uuids)
    }
}
