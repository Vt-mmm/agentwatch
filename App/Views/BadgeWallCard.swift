// Badge wall — grid of all badges, locked silhouette + unlocked colored.
// Duolingo "Awards" pattern: visible progression beyond level numbers.

import SwiftUI
import ClaudeWatchCore

struct BadgeWallCard: View {
    let badges: [Badge]
    let unlockedIds: Set<String>

    private let columns = [GridItem(.adaptive(minimum: 92), spacing: 10)]

    private var unlockedCount: Int { unlockedIds.count }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 6) {
                Image(systemName: "rosette")
                    .foregroundStyle(Claude.orange)
                SectionLabel(text: "Badges (\(unlockedCount)/\(badges.count))")
                Spacer()
            }
            LazyVGrid(columns: columns, spacing: 10) {
                ForEach(badges) { badge in
                    badgeTile(badge, unlocked: unlockedIds.contains(badge.id))
                }
            }
        }
        .claudeCard()
    }

    @ViewBuilder
    private func badgeTile(_ badge: Badge, unlocked: Bool) -> some View {
        VStack(spacing: 4) {
            Image(systemName: badge.icon)
                .font(.system(size: 24))
                .foregroundStyle(unlocked ? Claude.orange : Claude.textMuted.opacity(0.4))
                .frame(height: 32)
            Text(badge.title)
                .font(ClaudeFont.body(10))
                .fontWeight(.semibold)
                .foregroundStyle(unlocked ? Claude.textPrimary : Claude.textMuted)
                .lineLimit(1)
                .multilineTextAlignment(.center)
            Text(badge.description)
                .font(ClaudeFont.body(9))
                .foregroundStyle(Claude.textMuted)
                .lineLimit(2)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 10)
        .padding(.horizontal, 6)
        .background(unlocked ? Claude.surfaceAlt : Color.clear)
        .overlay(
            RoundedRectangle(cornerRadius: 8)
                .stroke(unlocked ? Claude.orange.opacity(0.4) : Claude.border, lineWidth: 1)
        )
        .clipShape(RoundedRectangle(cornerRadius: 8))
        .help(unlocked ? "✓ \(badge.title): \(badge.description)" : "🔒 \(badge.description)")
    }
}
