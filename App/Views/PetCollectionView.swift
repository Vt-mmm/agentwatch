// Tab "Pets" — gallery 28 sprite, click để chọn pet active.
// Layout: section "Pet đang dùng" (selected preview) + LazyVGrid toàn bộ catalog.
// Phase 1: XP/level hiển thị placeholder; logic thực ở phase 2.

import SwiftUI
import ClaudeWatchCore

struct PetCollectionView: View {
    @Environment(PetCollectionStore.self) private var store

    /// Grid tự co theo chiều rộng window — tối thiểu 110pt mỗi cell.
    private let columns = [GridItem(.adaptive(minimum: 110), spacing: 12)]

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                activePetSection
                allPetsSection
            }
            .padding(20)
        }
        .background(Claude.backgroundGradient)
    }

    // MARK: - Sections

    /// Pet đang được chọn — preview lớn hơn + info chi tiết.
    @ViewBuilder
    private var activePetSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            SectionLabel(text: "Pet đang dùng")

            if let activePet = store.pets[store.selectedId] {
                HStack(spacing: 16) {
                    // Sprite preview lớn hơn grid cell
                    ZStack {
                        RoundedRectangle(cornerRadius: 14, style: .continuous)
                            .fill(Claude.orangeSoft)
                            .frame(width: 88, height: 88)
                        SpritePet(state: .happy, characterName: activePet.characterId, level: activePet.level)
                            .frame(width: 72, height: 72)
                    }

                    VStack(alignment: .leading, spacing: 6) {
                        Text(PetCatalog.displayName(activePet.characterId))
                            .font(ClaudeFont.heading(16))
                            .foregroundStyle(Claude.textPrimary)

                        // Level badge — phase 2
                        Text(activePet.levelDescription)
                            .font(ClaudeFont.label(12))
                            .foregroundStyle(Claude.orange)
                            .padding(.horizontal, 8)
                            .padding(.vertical, 3)
                            .background(Capsule().fill(Claude.orangeSoft))

                        // XP bar 6px với caption — phase 2
                        XPBar(totalXP: activePet.xp, barHeight: 6, showCaption: true)

                        Text("Đang đồng hành cùng bạn")
                            .font(ClaudeFont.body(11))
                            .foregroundStyle(Claude.textMuted)
                    }

                    Spacer()
                }
                .padding(14)
                .claudeCard(padding: 0)
                .padding(.horizontal, 0)
            }
        }
    }

    /// Toàn bộ catalog 28 pet — LazyVGrid.
    @ViewBuilder
    private var allPetsSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            SectionLabel(text: "Bộ sưu tập (\(PetCatalog.all.count))")

            LazyVGrid(columns: columns, spacing: 12) {
                ForEach(PetCatalog.all, id: \.self) { id in
                    if let pet = store.pets[id] {
                        PetCardView(
                            pet: pet,
                            isSelected: store.selectedId == id
                        ) {
                            store.select(id)
                        }
                    }
                }
            }
        }
    }
}
