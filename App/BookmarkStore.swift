// Lưu danh sách prompt anh đánh dấu là "mẫu hay" để dùng cho team.
// Persist qua file sidecar ~/Library/Application Support/ClaudeWatchMac/bookmarks.json.
// File-based (chứ không UserDefaults) vì có thể chứa text dài + grow theo thời gian.

import Foundation
import Observation
import ClaudeWatchCore

struct BookmarkedPrompt: Codable, Identifiable, Equatable, Hashable {
    let id: String                  // PromptRecord.id (sessionUuid-lineIndex)
    let projectDisplay: String
    let sessionUuid: String
    let timestamp: Date
    let text: String
    let stars: Int
    let source: String              // SessionSource.rawValue

    var sessionSource: SessionSource {
        SessionSource(rawValue: source) ?? .cli
    }
}

@Observable
@MainActor
final class BookmarkStore {
    private(set) var items: [BookmarkedPrompt] = []
    private let fileURL: URL

    init() {
        let support = FileManager.default.urls(for: .applicationSupportDirectory,
                                                in: .userDomainMask).first!
        let dir = support.appendingPathComponent("ClaudeWatchMac", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        self.fileURL = dir.appendingPathComponent("bookmarks.json")
        load()
    }

    func contains(_ recordId: String) -> Bool {
        items.contains(where: { $0.id == recordId })
    }

    func toggle(_ record: PromptRecord) {
        if let idx = items.firstIndex(where: { $0.id == record.id }) {
            items.remove(at: idx)
        } else {
            items.insert(BookmarkedPrompt(
                id: record.id,
                projectDisplay: record.projectDisplay,
                sessionUuid: record.sessionUuid,
                timestamp: record.timestamp,
                text: record.text,
                stars: record.score.stars,
                source: record.source.rawValue
            ), at: 0)
            // Cap 200 để file không phình mãi.
            if items.count > 200 { items = Array(items.prefix(200)) }
        }
        save()
    }

    func remove(_ id: String) {
        items.removeAll { $0.id == id }
        save()
    }

    // MARK: - Persistence

    private func load() {
        guard let data = try? Data(contentsOf: fileURL),
              let decoded = try? JSONDecoder.iso.decode([BookmarkedPrompt].self, from: data) else {
            return
        }
        items = decoded
    }

    private func save() {
        guard let data = try? JSONEncoder.iso.encode(items) else { return }
        try? data.write(to: fileURL, options: .atomic)
    }
}

private extension JSONEncoder {
    static let iso: JSONEncoder = {
        let e = JSONEncoder()
        e.dateEncodingStrategy = .iso8601
        e.outputFormatting = [.prettyPrinted, .sortedKeys]
        return e
    }()
}

private extension JSONDecoder {
    static let iso: JSONDecoder = {
        let d = JSONDecoder()
        d.dateDecodingStrategy = .iso8601
        return d
    }()
}
