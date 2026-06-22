// Tab "Pets" — Trainer badge + active pet preview + 4 tier section gallery.
// Locked pet: grayscale + lock badge; tap → show unlock requirement.
// v0.4.0: thêm Trainer Level axis, tier-grouped sections.

import SwiftUI
import ClaudeWatchCore

struct PetCollectionView: View {
    @Environment(PetCollectionStore.self) private var store

    @State private var lockHint: LockHint?

    /// Grid tự co theo chiều rộng window — tối thiểu 110pt mỗi cell.
    private let columns = [GridItem(.adaptive(minimum: 110), spacing: 12)]

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                TrainerLevelBadge(
                    level: store.trainerLevel,
                    progress: store.trainerProgress
                )
                if store.streakDay > 0 {
                    HStack(spacing: 8) {
                        Image(systemName: "flame.fill")
                            .foregroundStyle(store.isStreakStaleToday ? Claude.textMuted : .orange)
                        Text(streakLabel)
                            .font(ClaudeFont.body(12))
                            .foregroundStyle(Claude.textPrimary)
                    }
                    .padding(.horizontal, 4)
                }
                activePetSection
                XPLedgerCard(events: store.ledgerSnapshot)
                ForEach(PetTier.allCases, id: \.self) { tier in
                    tierSection(tier)
                }
            }
            .padding(20)
        }
        .background(Claude.backgroundGradient)
        .alert(item: $lockHint) { hint in
            Alert(
                title: Text("Pet chưa unlock"),
                message: Text(hint.requirement),
                dismissButton: .default(Text("OK"))
            )
        }
    }

    /// Streak label — stale (chưa có session hôm nay) hiển thị rõ để không gian dối.
    private var streakLabel: String {
        if store.isStreakStaleToday {
            return "Streak \(store.streakDay) ngày — hôm nay chưa có session"
        }
        return "Streak \(store.streakDay) ngày liên tiếp"
    }

    // MARK: - Sections

    /// Pet đang được chọn — preview lớn hơn + info chi tiết.
    @ViewBuilder
    private var activePetSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            SectionLabel(text: "Pet đang dùng (đang train)")

            if let activePet = store.pets[store.selectedId] {
                HStack(spacing: 16) {
                    ZStack {
                        RoundedRectangle(cornerRadius: 14, style: .continuous)
                            .fill(Claude.orangeSoft)
                            .frame(width: 88, height: 88)
                        SpritePet(state: .happy, characterName: activePet.characterId,
                                  level: activePet.level)
                            .frame(width: 72, height: 72)
                    }

                    VStack(alignment: .leading, spacing: 6) {
                        Text(PetCatalog.displayName(activePet.characterId))
                            .font(ClaudeFont.heading(16))
                            .foregroundStyle(Claude.textPrimary)

                        Text(activePet.levelDescription)
                            .font(ClaudeFont.label(12))
                            .foregroundStyle(Claude.orange)
                            .padding(.horizontal, 8).padding(.vertical, 3)
                            .background(Capsule().fill(Claude.orangeSoft))

                        XPBar(totalXP: activePet.xp, barHeight: 6, showCaption: true)

                        Text("Prompt XP đổ vào pet này. Switch pet trong gallery để train con khác.")
                            .font(ClaudeFont.body(11))
                            .foregroundStyle(Claude.textMuted)
                            .lineLimit(2)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    Spacer()
                }
                .padding(14)
                .claudeCard(padding: 0)
            }
        }
    }

    /// Section cho 1 tier — header với label/icon + grid pets trong tier.
    @ViewBuilder
    private func tierSection(_ tier: PetTier) -> some View {
        let ids = PetUnlockGraph.petIds(for: tier)
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 6) {
                Image(systemName: tier.icon).foregroundStyle(Claude.orange)
                SectionLabel(text: "\(tier.label) (\(ids.count))")
                Spacer()
            }
            LazyVGrid(columns: columns, spacing: 12) {
                ForEach(ids, id: \.self) { id in
                    if let pet = store.pets[id] {
                        let locked = !store.isUnlocked(id)
                        PetCardView(
                            pet: pet,
                            isSelected: store.selectedId == id,
                            isLocked: locked
                        ) {
                            if locked {
                                lockHint = LockHint(
                                    petId: id,
                                    requirement: PetUnlockGraph.requirement(for: id).description()
                                )
                            } else {
                                _ = store.select(id)
                            }
                        }
                    }
                }
            }
        }
    }
}

// MARK: - Lock hint alert

private struct LockHint: Identifiable {
    let petId: String
    let requirement: String
    var id: String { petId }
}
