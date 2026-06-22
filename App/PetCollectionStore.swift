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

    // MARK: - Trainer Level (v0.4.0 — global progression axis)

    /// Tổng XP trainer global, separate khỏi pet XP. Source: session + streak +
    /// achievement. Derive trainerLevel qua TrainerProgress.level(forTotalXP:).
    private(set) var trainerXP: Int = 0

    /// Set pet đã đạt PL=10 và đã trao achievement bonus — tránh double-count.
    private var achievedPetIds: Set<String> = []

    /// Pets được grandfather từ phiên bản cũ (trước v0.4.0 có unlock gate).
    /// Pet trong set này luôn unlock dù không đạt new tier requirements.
    private var grandfatheredUnlocks: Set<String> = []

    /// Derived trainer level (1-30).
    var trainerLevel: Int { TrainerProgress.level(forTotalXP: trainerXP) }

    /// Trainer XP progress trong level hiện tại — for UI bar.
    var trainerProgress: (current: Int, needed: Int, level: Int) {
        TrainerProgress.progressInCurrentLevel(totalXP: trainerXP)
    }

    /// Check 1 pet đã unlock chưa — UI lock state.
    /// Grandfather override: pet đã có XP từ trước v0.4.0 luôn unlock.
    func isUnlocked(_ petId: String) -> Bool {
        if grandfatheredUnlocks.contains(petId) { return true }
        return PetUnlockGraph.isUnlocked(petId: petId, pets: pets, trainerLevel: trainerLevel)
    }

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

    private(set) var streakDay: Int = 0
    private(set) var lastActiveDayStart: Date?

    /// v0.4.1 fix #8: true nếu streak hôm nay đang "stale" — user đã streak X ngày
    /// nhưng hôm nay chưa có session. Hiển thị "X ngày (chưa hôm nay)" để không lừa.
    var isStreakStaleToday: Bool {
        guard streakDay > 0, let last = lastActiveDayStart else { return false }
        let todayStart = Calendar.current.startOfDay(for: Date())
        return last < todayStart
    }

    // MARK: - XP Ledger (v0.4.1 fix #5 — transparency)

    /// Append-only audit trail of every XP change. UI hiển thị last 50 entries.
    let ledger = XPLedger()

    /// Snapshot ledger cho UI — async vì XPLedger là actor.
    /// Cached gần nhất, refresh sau mỗi processReload.
    private(set) var ledgerSnapshot: [XPEvent] = []

    /// Refresh ledger snapshot (gọi sau khi mutate qua append).
    private func refreshLedgerSnapshot() {
        Task { [weak self] in
            guard let self else { return }
            let snap = await self.ledger.snapshot(limit: 50)
            await MainActor.run { self.ledgerSnapshot = snap }
        }
    }

    init() {
        load()
        loadSeenIds()
        refreshLedgerSnapshot()
    }

    // MARK: - Public API

    /// Chọn pet mới: validate + check unlock + update lastSeenAt + persist.
    /// Trả về false nếu pet chưa unlock — caller có thể show alert.
    @discardableResult
    func select(_ id: String) -> Bool {
        guard pets[id] != nil, isUnlocked(id) else { return false }
        selectedId = id
        pets[id]?.lastSeenAt = Date()
        persist()
        return true
    }

    /// Thêm XP vào pet đang selected (hoặc id cụ thể), recompute level, persist.
    /// Auto-trigger achievement bonus khi pet hit PL=10 lần đầu.
    func addXP(_ delta: Int, to characterId: String? = nil) {
        let targetId = characterId ?? selectedId
        guard pets[targetId] != nil else { return }
        let prevLevel = pets[targetId]?.level ?? 1
        let newXP = max(0, (pets[targetId]?.xp ?? 0) + delta)
        pets[targetId]?.xp = newXP
        let newLevel = XPEngine.level(forTotalXP: newXP)
        pets[targetId]?.level = newLevel

        // Achievement: pet đạt PL=10 lần đầu → +50 trainer XP bonus.
        if newLevel == 10 && prevLevel < 10 && !achievedPetIds.contains(targetId) {
            achievedPetIds.insert(targetId)
            trainerXP += TrainerProgress.xpPerAchievement
            appendEventsToLedger([XPEvent(
                kind: .achievement,
                amount: TrainerProgress.xpPerAchievement,
                petId: nil,
                detail: "\(targetId) đạt Lv 10 (master)"
            )])
        }
        persist()
    }

    /// Helper: append XP events vào ledger qua Task (actor bridge) + refresh snapshot.
    private func appendEventsToLedger(_ events: [XPEvent]) {
        guard !events.isEmpty else { return }
        Task { [weak self, events] in
            guard let self else { return }
            await self.ledger.append(contentsOf: events)
            let snap = await self.ledger.snapshot(limit: 50)
            await MainActor.run { self.ledgerSnapshot = snap }
        }
    }

    /// Cộng XP trực tiếp vào trainer (session/streak signals).
    func addTrainerXP(_ delta: Int) {
        guard delta != 0 else { return }
        trainerXP = max(0, trainerXP + delta)
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

        // Tính split delta: pet (prompt) vs trainer (session/streak).
        let split = XPEngine.computeSplitDelta(
            newPrompts: newPrompts,
            newSessions: newSessions,
            outlierIds: outlierIds,
            agentLoopIds: agentLoopIds,
            streakDay: todayStreak
        )

        // v0.4.1 fix #5: build XP events for audit trail.
        let activePet = selectedId
        var events: [XPEvent] = []
        for p in newPrompts {
            let amount = XPEngine.xpForPrompt(stars: p.score.stars)
            guard amount != 0 else { continue }
            events.append(XPEvent(
                timestamp: p.timestamp,
                kind: .prompt,
                amount: amount,
                petId: activePet,
                detail: "Prompt \(p.score.stars)★ • \(p.projectDisplay)"
            ))
        }
        for s in newSessions {
            let isOut = outlierIds.contains(s.id)
            let isLoop = agentLoopIds.contains(s.id)
            let amount = TrainerProgress.xpForSession(isOutlier: isOut, isAgentLoop: isLoop)
            let kind: XPEventKind = amount < 5 ? .penalty : .session
            let badge = isOut ? " (outlier)" : isLoop ? " (agent loop)" : ""
            events.append(XPEvent(
                timestamp: s.firstTimestamp ?? Date(),
                kind: kind,
                amount: amount,
                petId: nil,
                detail: "Session\(badge) • \(s.projectDisplay)"
            ))
        }
        if !newSessions.isEmpty && todayStreak >= 1 {
            let amount = TrainerProgress.xpForStreakDay(todayStreak)
            events.append(XPEvent(
                kind: .streak,
                amount: amount,
                petId: nil,
                detail: "Streak day \(todayStreak)"
            ))
        }
        appendEventsToLedger(events)

        // Pet XP → active pet (prompt training).
        if split.petXP != 0 { addXP(split.petXP) }
        // Trainer XP → global (session/streak).
        if split.trainerXP != 0 { addTrainerXP(split.trainerXP) }

        // Đánh dấu đã seen — insert có bounded eviction để tránh unbounded growth.
        for p in newPrompts { insertSeenPrompt(p.id) }
        for s in newSessions { insertSeenSession(s.id) }
        persistSeenIds()
    }

    // MARK: - Bounded set helpers

    /// Insert prompt id với FIFO eviction khi vượt maxSeenPromptIds.
    ///
    /// KNOWN LIMITATION (v0.4.1 audit #6): nếu user expand scope Coaching tới range
    /// chứa prompts cũ đã bị evict (>50k prompts trước trong history), những prompts
    /// đó sẽ được count XP LẠI lần 2. Edge case hiếm cho personal use, accepted.
    ///
    /// Mitigation tương lai: switch sang per-session high-water mark (track max line
    /// index per sessionUuid) — bounded O(num_sessions) thay O(num_prompts).
    ///
    /// KNOWN LIMITATION (v0.4.1 audit #10): nếu user xoá UserDefaults thủ công nhưng
    /// JSONL còn nguyên trên disk, lần load tiếp theo sẽ scan + count XP TOÀN BỘ
    /// history từ đầu → pet/trainer level tăng đột ngột. Đây là "reset semantics"
    /// expected nhưng không document trong UI.
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
                trainerXP = decoded.trainerXP
                achievedPetIds = Set(decoded.achievedPetIds)
                grandfatheredUnlocks = Set(decoded.grandfatheredUnlocks)
                // Đảm bảo có đủ 28 entry — thêm pet mới nếu catalog tăng.
                seedMissingPets()

                // v0.4.1 migration fix #1: GRANDFATHER pets.
                // Pet có xp>0 từ phiên bản cũ (trước có unlock gate) → mark unlocked
                // vĩnh viễn bằng grandfatheredUnlocks. Trùng selectedId cũ cũng grandfather.
                // Không silently downgrade pet user đã build.
                grandfatherLegacyPets(previousSelectedId: decoded.selectedId)

                // v0.4.1 fix #2: backfill achievement XP cho pet đã PL=10 trước v0.4.0.
                backfillAchievements()

                // Validate selectedId — sau grandfather, pet cũ unlock OK.
                let preferred = decoded.selectedId
                if pets[preferred] != nil && isUnlocked(preferred) {
                    selectedId = preferred
                } else {
                    selectedId = "clawd"
                }
                // Persist các thay đổi migration nếu có.
                persist()
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

    /// v0.4.1 fix #1: pet đã có xp > 0 từ phiên bản cũ HOẶC trùng previousSelectedId
    /// → grandfather (luôn unlock dù không match tier requirement mới).
    /// Tránh silently downgrade pet user đã build công.
    private func grandfatherLegacyPets(previousSelectedId: String) {
        for (id, pet) in pets {
            if pet.xp > 0 || id == previousSelectedId {
                grandfatheredUnlocks.insert(id)
            }
        }
    }

    /// v0.4.1 fix #2: backfill achievement bonus cho pet đã PL=10 trước khi feature
    /// achievedPetIds tồn tại. Mark all + grant +50 trainer XP retroactive.
    /// Log từng event vào ledger để user thấy migration đã add bao nhiêu XP.
    private func backfillAchievements() {
        var events: [XPEvent] = []
        for (id, pet) in pets where pet.level >= 10 && !achievedPetIds.contains(id) {
            achievedPetIds.insert(id)
            trainerXP += TrainerProgress.xpPerAchievement
            events.append(XPEvent(
                kind: .migration,
                amount: TrainerProgress.xpPerAchievement,
                petId: nil,
                detail: "Backfill: \(id) đã đạt Lv 10 từ trước v0.4.1"
            ))
        }
        appendEventsToLedger(events)
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
            schemaVersion: PetCollection.currentSchemaVersion,
            pets: pets,
            selectedId: selectedId,
            trainerXP: trainerXP,
            achievedPetIds: Array(achievedPetIds),
            grandfatheredUnlocks: Array(grandfatheredUnlocks)
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
