// Cell đơn trong gallery pet — 96×96 sprite preview, tên, level pill.
// Selected: viền cam 2pt + checkmark góc trên phải.
// Phase 1: level luôn = 1, XP placeholder cho phase 2.

import SwiftUI
import ClaudeWatchCore

struct PetCardView: View {
    let pet: PetProgress
    let isSelected: Bool
    let onTap: () -> Void

    private let cardSize: CGFloat = 110
    private let spriteSize: CGFloat = 64

    var body: some View {
        ZStack(alignment: .topTrailing) {
            VStack(spacing: 4) {
                // Sprite preview pixel-perfect
                SpritePet(state: .happy, characterName: pet.characterId, level: pet.level)
                    .frame(width: spriteSize, height: spriteSize)

                // Tên pet
                Text(PetCatalog.displayName(pet.characterId))
                    .font(.system(size: 10, weight: .medium))
                    .foregroundStyle(Claude.textPrimary)
                    .lineLimit(1)
                    .minimumScaleFactor(0.8)

                // Level pill
                Text(pet.levelDescription)
                    .font(.system(size: 9, weight: .semibold))
                    .foregroundStyle(isSelected ? Claude.orange : Claude.textMuted)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(
                        Capsule()
                            .fill(isSelected ? Claude.orangeSoft : Claude.surface)
                    )

                // XP bar 2px — phase 2
                XPBar(totalXP: pet.xp, barHeight: 2, showCaption: false)
                    .frame(width: cardSize - 16)
            }
            .frame(width: cardSize, height: cardSize)
            .background(
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .fill(Claude.surface)
            )
            .overlay(
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .strokeBorder(
                        isSelected ? Claude.orange : Claude.border,
                        lineWidth: isSelected ? 2 : 1
                    )
            )

            // Checkmark góc trên phải khi selected
            if isSelected {
                Image(systemName: "checkmark.circle.fill")
                    .font(.system(size: 14, weight: .bold))
                    .foregroundStyle(Claude.orange)
                    .background(Circle().fill(Claude.backgroundGradient).padding(2))
                    .offset(x: 4, y: -4)
            }
        }
        .contentShape(Rectangle())
        .onTapGesture { onTap() }
        .animation(.easeInOut(duration: 0.15), value: isSelected)
    }
}
