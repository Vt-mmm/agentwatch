// Map sessionUuid → user-defined alias/note (1-60 char).
// Persist UserDefaults dictionary, observable trên main thread cho UI bind.

import Foundation
import SwiftUI

@MainActor
@Observable
final class SessionAliasStore {
    static let shared = SessionAliasStore()

    private static let udKey = "SessionAliasStore.v1"
    private static let maxLength = 60

    private var aliases: [String: String] = [:]

    init() { load() }

    /// Đọc alias cho 1 session, nil nếu user chưa đặt.
    func alias(for sessionUuid: String) -> String? {
        let s = aliases[sessionUuid]
        return (s?.isEmpty == false) ? s : nil
    }

    /// Set alias (trim + cap 60 char). Empty → remove key.
    func setAlias(_ value: String, for sessionUuid: String) {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty {
            aliases.removeValue(forKey: sessionUuid)
        } else {
            aliases[sessionUuid] = String(trimmed.prefix(Self.maxLength))
        }
        persist()
    }

    // MARK: - Persistence

    private func persist() {
        guard let data = try? JSONEncoder().encode(aliases) else { return }
        UserDefaults.standard.set(data, forKey: Self.udKey)
    }

    private func load() {
        guard let data = UserDefaults.standard.data(forKey: Self.udKey),
              let decoded = try? JSONDecoder().decode([String: String].self, from: data) else {
            return
        }
        aliases = decoded
    }
}
