// Store quản lý bộ sưu tập 28 pet — Observable, persist qua UserDefaults JSON.
// Migration: đọc SpriteStore.selected (Int) cũ nếu PetCollection.v1 chưa có.
// Phase 2: thêm XP engine, streak tracking, dedup seenIds.

import Foundation
import Observation
import ClaudeWatchCore

@Observable
@MainActor
final class PetCollectionStore {
    private let udKey = "PetCollection.v1"
    private let legacyUdKey = "SpriteStore.selected"
    /// Persist seen ids để tránh double-count XP qua app restart.
    private let seenIdsKey = "PetCollection.seenIds.v1"

    /// Map characterId → PetProgress (28 entries).
    private(set) var pets: [String: PetProgress] = [:]

    /// Id pet đang chọn — thay đổi ngay lập tức, persist async.
    private(set) var selectedId: String = "clawd"

    /// Bridge cho legacy code còn dùng currentName.
    var currentName: String { selectedId }

    // MARK: - Dedup sets (persist across restart, bounded size)

    /// Giới hạn kích thước set để tránh unbounded growth sau nhiều tháng dùng.
    /// 50_000 prompt id ≈ ~3.5 MB RAM/disk (70-byte UUID × 50k) — acceptable.
    private static let maxSeenPromptIds = 50_000
    /// Session id ít hơn nhiều so với prompt — 10k là đủ cho vài năm dùng.
    private static let maxSeenSessionIds = 10_000

    /// Tập id prompt đã tính XP — dùng Set cho O(1) lookup.
    private var seenPromptIds: Set<String> = []
    /// Thứ tự insertion của seenPromptIds — dùng cho FIFO eviction khi vượt cap.
    private var seenPromptOrder: [String] = []

    /// Tập id session đã tính XP — dùng Set cho O(1) lookup.
    private var seenSessionIds: Set<String> = []
    /// Thứ tự insertion của seenSessionIds — dùng cho FIFO eviction khi vượt cap.
    private var seenSessionOrder: [String] = []

    // MARK: - Streak tracking (in-memory, persist trong PetCollection)

    private var streakDay: Int = 0
    private var lastActiveDayStart: Date?

    init() {
        load()
        loadSeenIds()
    }

    // MARK: - Public API

    /// Chọn pet mới: validate, update lastSeenAt, persist.
    func select(_ id: String) {
        guard pets[id] != nil else { return }
        selectedId = id
        pets[id]?.lastSeenAt = Date()
        persist()
    }

    /// Thêm XP vào pet đang selected (hoặc id cụ thể), recompute level, persist.
    func addXP(_ delta: Int, to characterId: String? = nil) {
        let targetId = characterId ?? selectedId
        guard pets[targetId] != nil else { return }
        let newXP = max(0, (pets[targetId]?.xp ?? 0) + delta)
        pets[targetId]?.xp = newXP
        pets[targetId]?.level = XPEngine.level(forTotalXP: newXP)
        persist()
    }

    /// Nhận snapshot mới từ CoachingDataStore.reload — tính delta XP và áp dụng.
    /// Idempotent: gọi nhiều lần cùng snapshot KHÔNG double-count nhờ seenIds.
    func processReload(
        records: [PromptRecord],
        sessions: [SessionSummary],
        outlierIds: Set<String>,
        agentLoopIds: Set<String>
    ) {
        // Lọc records/sessions chưa tính XP
        let newPrompts = records.filter { !seenPromptIds.contains($0.id) }
        let newSessions = sessions.filter { !seenSessionIds.contains($0.id) }

        guard !newPrompts.isEmpty || !newSessions.isEmpty else { return }

        // Cập nhật streak day nếu có session mới hôm nay
        let todayStreak = updateStreak(hasSessions: !newSessions.isEmpty)

        // Tính delta
        let delta = XPEngine.computeDelta(
            newPrompts: newPrompts,
            newSessions: newSessions,
            outlierIds: outlierIds,
            agentLoopIds: agentLoopIds,
            streakDay: todayStreak
        )

        // Áp dụng XP (chỉ khi có delta thực sự)
        if delta != 0 {
            addXP(delta)
        }

        // Đánh dấu đã seen — insert có bounded eviction để tránh unbounded growth.
        for p in newPrompts { insertSeenPrompt(p.id) }
        for s in newSessions { insertSeenSession(s.id) }
        persistSeenIds()
    }

    // MARK: - Bounded set helpers

    /// Insert prompt id với FIFO eviction khi vượt maxSeenPromptIds.
    /// XP dedup vẫn đúng: entry bị evict là prompt cũ (>50k prompts trước),
    /// user sẽ không gặp lại chúng trong window hiện tại → edge case chấp nhận được.
    private func insertSeenPrompt(_ id: String) {
        guard !seenPromptIds.contains(id) else { return }
        seenPromptIds.insert(id)
        seenPromptOrder.append(id)
        // Evict oldest khi vượt cap — removeFirst() O(n) nhưng hiếm khi trigger.
        while seenPromptOrder.count > Self.maxSeenPromptIds {
            let evicted = seenPromptOrder.removeFirst()
            seenPromptIds.remove(evicted)
        }
    }

    /// Insert session id với FIFO eviction khi vượt maxSeenSessionIds.
    private func insertSeenSession(_ id: String) {
        guard !seenSessionIds.contains(id) else { return }
        seenSessionIds.insert(id)
        seenSessionOrder.append(id)
        while seenSessionOrder.count > Self.maxSeenSessionIds {
            let evicted = seenSessionOrder.removeFirst()
            seenSessionIds.remove(evicted)
        }
    }

    // MARK: - Streak

    /// Cập nhật streak dựa trên ngày hôm nay. Trả về streakDay hiện tại.
    /// Chỉ tăng streak khi có session mới trong ngày.
    private func updateStreak(hasSessions: Bool) -> Int {
        guard hasSessions else { return streakDay }

        let cal = Calendar.current
        let todayStart = cal.startOfDay(for: Date())

        if let last = lastActiveDayStart {
            if todayStart == last {
                // Cùng ngày → streak không đổi
                return streakDay
            } else if let yesterday = cal.date(byAdding: .day, value: -1, to: todayStart),
                      last == yesterday {
                // Ngày liên tiếp → tăng streak
                streakDay += 1
            } else if last > todayStart {
                // Clock backward defense — bỏ qua
                return streakDay
            } else {
                // Ngắt quãng ≥2 ngày → reset
                streakDay = 1
            }
        } else {
            streakDay = 1
        }

        lastActiveDayStart = todayStart
        return streakDay
    }

    // MARK: - Persistence

    private func load() {
        // Thử load PetCollection.v1 trước.
        if let data = UserDefaults.standard.data(forKey: udKey) {
            do {
                let decoded = try JSONDecoder().decode(PetCollection.self, from: data)
                pets = decoded.pets
                // Đảm bảo có đủ 28 entry — thêm pet mới nếu catalog tăng.
                seedMissingPets()
                // Validate selectedId còn hợp lệ.
                selectedId = pets[decoded.selectedId] != nil ? decoded.selectedId : "clawd"
                return
            } catch {
                // JSON decode fail → fallback seed an toàn, không crash.
                print("[PetCollectionStore] decode error: \(error) — seeding defaults")
            }
        }

        // Không có PetCollection.v1 → seed 28 pet mặc định.
        seedAllPets()

        // Migration legacy SpriteStore.selected (Int 0..26 → char%02d).
        if let legacyIdx = UserDefaults.standard.object(forKey: legacyUdKey) as? Int,
           legacyIdx >= 0, legacyIdx < 27 {
            let migratedId = String(format: "char%02d", legacyIdx)
            selectedId = migratedId
        } else {
            selectedId = "clawd"
        }

        persist()
    }

    private func seedAllPets() {
        pets = [:]
        for id in PetCatalog.all {
            pets[id] = PetProgress(characterId: id)
        }
    }

    /// Thêm pet còn thiếu (catalog tăng giữa phiên bản app).
    private func seedMissingPets() {
        for id in PetCatalog.all where pets[id] == nil {
            pets[id] = PetProgress(characterId: id)
        }
    }

    private func persist() {
        let snapshot = PetCollection(
            schemaVersion: 1,
            pets: pets,
            selectedId: selectedId
        )
        guard let data = try? JSONEncoder().encode(snapshot) else { return }
        UserDefaults.standard.set(data, forKey: udKey)
    }

    // MARK: - SeenIds persistence

    /// Persist seenPromptIds + seenSessionIds (bao gồm order arrays) vào UserDefaults.
    private func persistSeenIds() {
        let combined = SeenIdsSnapshot(
            schemaVersion: SeenIdsSnapshot.currentSchemaVersion,
            promptIds: Array(seenPromptIds),
            sessionIds: Array(seenSessionIds),
            promptOrder: seenPromptOrder,
            sessionOrder: seenSessionOrder,
            streakDay: streakDay,
            lastActiveDayStart: lastActiveDayStart
        )
        guard let data = try? JSONEncoder().encode(combined) else { return }
        UserDefaults.standard.set(data, forKey: seenIdsKey)
    }

    private func loadSeenIds() {
        guard let data = UserDefaults.standard.data(forKey: seenIdsKey),
              let decoded = try? JSONDecoder().decode(SeenIdsSnapshot.self, from: data) else {
            return
        }
        seenPromptIds = Set(decoded.promptIds)
        seenSessionIds = Set(decoded.sessionIds)
        streakDay = decoded.streakDay
        lastActiveDayStart = decoded.lastActiveDayStart

        // Forward migration: payload lưu từ schema cũ (trước khi có order arrays)
        // → seed order từ set theo thứ tự tuỳ ý (best-effort, không mất XP).
        if decoded.schemaVersion < SeenIdsSnapshot.currentSchemaVersion {
            seenPromptOrder = decoded.promptOrder.isEmpty
                ? Array(seenPromptIds)
                : decoded.promptOrder
            seenSessionOrder = decoded.sessionOrder.isEmpty
                ? Array(seenSessionIds)
                : decoded.sessionOrder
        } else {
            seenPromptOrder = decoded.promptOrder
            seenSessionOrder = decoded.sessionOrder
        }
    }
}

// MARK: - SeenIds snapshot (internal, not public)

/// Codable container cho dedup state — persist riêng khỏi PetCollection.
///
/// Schema v2 thêm:
///   - schemaVersion: Int  → dùng cho forward migration
///   - promptOrder: [String] → insertion-order array cho FIFO eviction
///   - sessionOrder: [String] → insertion-order array cho FIFO eviction
///
/// Backward compat: các field mới có default value nên payload cũ (v1, không có
/// schemaVersion/order) vẫn decode thành công — migration xảy ra trong loadSeenIds().
private struct SeenIdsSnapshot: Codable {
    /// Phiên bản schema hiện tại. Tăng lên khi thêm field mới cần migration.
    static let currentSchemaVersion = 2

    var schemaVersion: Int
    var promptIds: [String]
    var sessionIds: [String]
    /// Insertion-order list cho promptIds — dùng cho FIFO eviction khi vượt cap.
    var promptOrder: [String]
    /// Insertion-order list cho sessionIds — dùng cho FIFO eviction khi vượt cap.
    var sessionOrder: [String]
    var streakDay: Int
    var lastActiveDayStart: Date?

    // Custom CodingKeys để decode payload cũ thiếu field mới với giá trị default.
    private enum CodingKeys: String, CodingKey {
        case schemaVersion, promptIds, sessionIds, promptOrder, sessionOrder
        case streakDay, lastActiveDayStart
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        schemaVersion     = (try? c.decode(Int.self,    forKey: .schemaVersion))     ?? 1
        promptIds         = (try? c.decode([String].self, forKey: .promptIds))        ?? []
        sessionIds        = (try? c.decode([String].self, forKey: .sessionIds))       ?? []
        promptOrder       = (try? c.decode([String].self, forKey: .promptOrder))      ?? []
        sessionOrder      = (try? c.decode([String].self, forKey: .sessionOrder))     ?? []
        streakDay         = (try? c.decode(Int.self,    forKey: .streakDay))          ?? 0
        lastActiveDayStart = try? c.decode(Date.self,   forKey: .lastActiveDayStart)
    }

    init(schemaVersion: Int, promptIds: [String], sessionIds: [String],
         promptOrder: [String], sessionOrder: [String],
         streakDay: Int, lastActiveDayStart: Date?) {
        self.schemaVersion      = schemaVersion
        self.promptIds          = promptIds
        self.sessionIds         = sessionIds
        self.promptOrder        = promptOrder
        self.sessionOrder       = sessionOrder
        self.streakDay          = streakDay
        self.lastActiveDayStart = lastActiveDayStart
    }
}
