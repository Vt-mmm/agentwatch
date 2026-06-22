// Trainer Level header badge — hiển thị global level + XP progress bar.
// Place ở đầu PetCollectionView để user thấy progression chính khi vào tab Pets.

import SwiftUI
import ClaudeWatchCore

struct TrainerLevelBadge: View {
    let level: Int
    let progress: (current: Int, needed: Int, level: Int)

    private var ratio: Double {
        // v0.4.1 fix #9: tại MAX level, bar luôn full (visual reward) thay vì tính
        // ratio bằng 0 do progress.current = 0 khi vượt cumulative cap.
        if level >= TrainerProgress.maxLevel { return 1.0 }
        guard progress.needed > 0 else { return 1.0 }
        return min(1.0, Double(progress.current) / Double(progress.needed))
    }

    private var isMaxed: Bool { level >= TrainerProgress.maxLevel }

    var body: some View {
        HStack(spacing: 14) {
            ZStack {
                Circle()
                    .fill(LinearGradient(
                        colors: [Claude.orange, Claude.orangeSoft],
                        startPoint: .topLeading, endPoint: .bottomTrailing
                    ))
                    .frame(width: 56, height: 56)
                VStack(spacing: 0) {
                    Text("TL")
                        .font(.system(size: 9, weight: .bold))
                        .foregroundStyle(.white.opacity(0.8))
                    Text("\(level)")
                        .font(.system(size: 22, weight: .heavy))
                        .foregroundStyle(.white)
                }
            }

            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 6) {
                    Text("Trainer Level \(level)")
                        .font(ClaudeFont.heading(15))
                        .foregroundStyle(Claude.textPrimary)
                    if isMaxed {
                        Text("MAX")
                            .font(.system(size: 9, weight: .bold))
                            .foregroundStyle(.white)
                            .padding(.horizontal, 6).padding(.vertical, 2)
                            .background(Capsule().fill(Claude.orange))
                    }
                }

                // XP bar
                GeometryReader { geo in
                    ZStack(alignment: .leading) {
                        RoundedRectangle(cornerRadius: 4)
                            .fill(Claude.surfaceAlt)
                        RoundedRectangle(cornerRadius: 4)
                            .fill(LinearGradient(
                                colors: [Claude.orange, Claude.orangeSoft],
                                startPoint: .leading, endPoint: .trailing
                            ))
                            .frame(width: max(4, geo.size.width * ratio))
                    }
                }
                .frame(height: 8)

                if isMaxed {
                    Text("Đã đạt level cao nhất — tiếp tục nhận achievement bonus khi master pet mới.")
                        .font(ClaudeFont.body(11))
                        .foregroundStyle(Claude.textMuted)
                } else {
                    Text("\(progress.current) / \(progress.needed) XP → Lv \(level + 1)")
                        .font(ClaudeFont.mono(11))
                        .foregroundStyle(Claude.textMuted)
                }
            }
            Spacer()
        }
        .padding(14)
        .claudeCard(padding: 0)
        .animation(.easeOut(duration: 0.3), value: level)
    }
}
