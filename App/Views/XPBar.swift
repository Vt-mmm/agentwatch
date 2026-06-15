// Thanh XP nhỏ dùng chung — hiển thị progress trong level hiện tại.
// Dùng GeometryReader để fill chiều ngang theo tỷ lệ thực tế.

import SwiftUI
import ClaudeWatchCore

struct XPBar: View {
    let totalXP: Int
    /// Chiều cao của bar.
    var barHeight: CGFloat = 4
    /// Hiển thị caption "Lv X · current / needed XP" bên dưới bar.
    var showCaption: Bool = true

    private var progress: (current: Int, needed: Int, level: Int) {
        XPEngine.progressInCurrentLevel(totalXP: totalXP)
    }

    private var fillFraction: Double {
        let p = progress
        guard p.needed > 0 else { return 1.0 }
        return min(1.0, Double(p.current) / Double(p.needed))
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            // Bar
            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    RoundedRectangle(cornerRadius: barHeight / 2)
                        .fill(Claude.border)
                        .frame(height: barHeight)
                    RoundedRectangle(cornerRadius: barHeight / 2)
                        .fill(Claude.orange)
                        .frame(width: geo.size.width * fillFraction, height: barHeight)
                }
            }
            .frame(height: barHeight)

            // Caption
            if showCaption {
                let p = progress
                Text("Lv \(p.level) · \(p.current) / \(p.needed) XP")
                    .font(.system(size: 10))
                    .foregroundStyle(Claude.textMuted)
            }
        }
    }
}
