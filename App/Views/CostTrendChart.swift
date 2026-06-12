// Mini bar chart 7 ngày cost. Pure SwiftUI, không phụ thuộc Charts framework
// để giữ macOS 14 compat. Bar cao nhất = max value; bar khác scale theo tỷ lệ.
// Label dưới mỗi cột = tên thứ Việt (T2-CN) auto-tính từ Date của bucket.

import SwiftUI

struct CostTrendChart: View {
    /// Bucket mỗi ngày, [oldest → latest]. Length thường = 7.
    let buckets: [DailyCostBucket]

    private var maxValue: Double {
        max(buckets.map(\.cost).max() ?? 0, 0.000001)
    }

    var body: some View {
        if buckets.isEmpty {
            placeholder
        } else {
            GeometryReader { geo in
                HStack(alignment: .bottom, spacing: 6) {
                    ForEach(Array(buckets.enumerated()), id: \.offset) { _, b in
                        VStack(spacing: 4) {
                            ZStack(alignment: .bottom) {
                                RoundedRectangle(cornerRadius: 4)
                                    .fill(Claude.surfaceAlt)
                                    .frame(maxHeight: .infinity)
                                RoundedRectangle(cornerRadius: 4)
                                    .fill(barColor(for: b.cost))
                                    .frame(height: max(2, (b.cost / maxValue) * (geo.size.height - 22)))
                            }
                            Text(Self.weekdayLabel(for: b.date))
                                .font(ClaudeFont.label(9))
                                .foregroundStyle(Claude.textMuted)
                        }
                        .frame(maxWidth: .infinity)
                    }
                }
            }
        }
    }

    private var placeholder: some View {
        Text("Chưa đủ dữ liệu 7 ngày")
            .font(ClaudeFont.body(11))
            .foregroundStyle(Claude.textMuted)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func barColor(for value: Double) -> Color {
        value > 0 ? Claude.orange : Claude.border
    }

    /// Map weekday Việt: Mon→T2, Tue→T3, Wed→T4, Thu→T5, Fri→T6, Sat→T7, Sun→CN.
    static func weekdayLabel(for date: Date) -> String {
        let cal = Calendar(identifier: .gregorian)
        // Calendar.weekday: 1=Sun, 2=Mon, …, 7=Sat
        let wd = cal.component(.weekday, from: date)
        switch wd {
        case 1: return "CN"
        case 2: return "T2"
        case 3: return "T3"
        case 4: return "T4"
        case 5: return "T5"
        case 6: return "T6"
        case 7: return "T7"
        default: return ""
        }
    }
}
