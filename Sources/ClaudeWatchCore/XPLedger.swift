// XP audit trail — append-only event log để user xem chính xác XP đến từ đâu.
// "Dữ liệu bám sát, minh bạch" yêu cầu user verify từng entry.
//
// KISS: 1 enum kind + 1 struct entry, cap 500 entries, persist UserDefaults.
// Không phải full event store — chỉ recent N entries cho UI display.

import Foundation

public enum XPEventKind: String, Codable, Sendable {
    case prompt          // Pet XP từ 1 prompt
    case session         // Trainer XP từ session complete
    case streak          // Trainer XP từ streak day
    case achievement     // Trainer XP từ pet đạt PL=10
    case migration       // Trainer XP backfill từ migration (v0.4.1 upgrade)
    case penalty         // Negative XP — outlier hoặc agent loop

    public var label: String {
        switch self {
        case .prompt:      return "Prompt"
        case .session:     return "Session"
        case .streak:      return "Streak"
        case .achievement: return "Achievement"
        case .migration:   return "Migration"
        case .penalty:     return "Penalty"
        }
    }

    public var icon: String {
        switch self {
        case .prompt:      return "text.bubble"
        case .session:     return "checkmark.circle"
        case .streak:      return "flame"
        case .achievement: return "rosette"
        case .migration:   return "arrow.up.circle"
        case .penalty:     return "exclamationmark.triangle"
        }
    }
}

public struct XPEvent: Codable, Sendable, Identifiable, Equatable {
    public let id: String
    public let timestamp: Date
    public let kind: XPEventKind
    public let amount: Int
    /// Nơi XP đi (pet) — nil nếu trainer XP.
    public let petId: String?
    /// Description ngắn để user verify, vd "Prompt 5★ (char12)", "Session abc-123".
    public let detail: String

    public init(id: String = UUID().uuidString,
                timestamp: Date = Date(),
                kind: XPEventKind,
                amount: Int,
                petId: String? = nil,
                detail: String) {
        self.id = id
        self.timestamp = timestamp
        self.kind = kind
        self.amount = amount
        self.petId = petId
        self.detail = detail
    }

    /// Pet-axis hay trainer-axis — derive cho UI tag.
    public var isPetXP: Bool { petId != nil }
}

/// Append-only ring buffer of XP events. 500 entries ≈ vài tuần ngày active.
public actor XPLedger {
    public static let maxEntries = 500
    private static let udKey = "XPLedger.v1"

    public private(set) var events: [XPEvent] = []

    public init() {
        // Actor init không thể gọi isolated method trực tiếp — inline load logic.
        guard let data = UserDefaults.standard.data(forKey: Self.udKey),
              let decoded = try? JSONDecoder().decode([XPEvent].self, from: data) else {
            return
        }
        events = decoded
    }

    /// Append 1 event, evict oldest nếu vượt cap.
    public func append(_ event: XPEvent) {
        events.append(event)
        if events.count > Self.maxEntries {
            events.removeFirst(events.count - Self.maxEntries)
        }
        persist()
    }

    /// Append batch — atomic persist 1 lần.
    public func append(contentsOf newEvents: [XPEvent]) {
        guard !newEvents.isEmpty else { return }
        events.append(contentsOf: newEvents)
        if events.count > Self.maxEntries {
            events.removeFirst(events.count - Self.maxEntries)
        }
        persist()
    }

    /// Snapshot không-mutate cho UI read.
    public func snapshot(limit: Int = 50) -> [XPEvent] {
        Array(events.suffix(limit).reversed())   // newest first
    }

    /// Tổng XP per kind trong window — phục vụ "this week breakdown" view.
    public func sumByKind(since: Date) -> [XPEventKind: Int] {
        var result: [XPEventKind: Int] = [:]
        for e in events where e.timestamp >= since {
            result[e.kind, default: 0] += e.amount
        }
        return result
    }

    // MARK: - Persistence

    private func persist() {
        guard let data = try? JSONEncoder().encode(events) else { return }
        UserDefaults.standard.set(data, forKey: Self.udKey)
    }
}
