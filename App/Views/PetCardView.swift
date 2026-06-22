// Cell đơn trong gallery pet — 96×96 sprite preview, tên, level pill.
// Selected: viền cam 2pt + checkmark góc trên phải.
// Locked (v0.4.0): grayscale + lock icon overlay + dim opacity.

import SwiftUI
import ClaudeWatchCore

struct PetCardView: View {
    let pet: PetProgress
    let isSelected: Bool
    /// True nếu pet chưa unlock — render grayscale + lock overlay.
    var isLocked: Bool = false
    let onTap: () -> Void

    private let cardSize: CGFloat = 110
    private let spriteSize: CGFloat = 64

    var body: some View {
        ZStack(alignment: .topTrailing) {
            VStack(spacing: 4) {
                // Sprite preview pixel-perfect — grayscale khi locked.
                SpritePet(state: .happy, characterName: pet.characterId, level: pet.level)
                    .frame(width: spriteSize, height: spriteSize)
                    .saturation(isLocked ? 0 : 1)
                    .opacity(isLocked ? 0.35 : 1)

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

            // Checkmark / lock badge góc trên phải
            if isLocked {
                Image(systemName: "lock.fill")
                    .font(.system(size: 12, weight: .bold))
                    .foregroundStyle(.white)
                    .padding(5)
                    .background(Circle().fill(Color.black.opacity(0.6)))
                    .offset(x: 4, y: -4)
            } else if isSelected {
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
        .animation(.easeInOut(duration: 0.2), value: isLocked)
    }
}
