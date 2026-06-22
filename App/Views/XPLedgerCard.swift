// XP audit trail UI — list 20 event gần nhất + tổng theo kind tuần này.
// Mỗi entry hiển thị: icon kind, amount (+/-), detail string, timestamp tương đối.
// "Dữ liệu bám sát, minh bạch" — user verify được từng XP delta đến từ đâu.

import SwiftUI
import ClaudeWatchCore

struct XPLedgerCard: View {
    /// Snapshot từ PetCollectionStore — newest-first, max 50 entries.
    let events: [XPEvent]

    /// Tổng XP cộng dồn tuần này, split per kind cho stat row.
    private var weekSums: [XPEventKind: Int] {
        let weekAgo = Date().addingTimeInterval(-7 * 24 * 3600)
        var result: [XPEventKind: Int] = [:]
        for e in events where e.timestamp >= weekAgo {
            result[e.kind, default: 0] += e.amount
        }
        return result
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 6) {
                Image(systemName: "list.bullet.rectangle.portrait")
                    .foregroundStyle(Claude.orange)
                SectionLabel(text: "XP Ledger (audit trail)")
                Spacer()
                Text("\(events.count) event")
                    .font(ClaudeFont.mono(11))
                    .foregroundStyle(Claude.textMuted)
            }

            // Stat row — tổng per kind trong 7 ngày
            weeklyStatRow

            if events.isEmpty {
                Text("Chưa có XP event nào — reload Coaching tab để bắt đầu tích lũy.")
                    .font(ClaudeFont.body(12))
                    .foregroundStyle(Claude.textMuted)
            } else {
                VStack(alignment: .leading, spacing: 6) {
                    ForEach(events.prefix(20)) { event in
                        eventRow(event)
                    }
                }
            }
        }
        .claudeCard()
    }

    @ViewBuilder
    private var weeklyStatRow: some View {
        let kinds: [XPEventKind] = [.prompt, .session, .streak, .achievement, .penalty]
        HStack(spacing: 10) {
            ForEach(kinds, id: \.self) { kind in
                let total = weekSums[kind] ?? 0
                VStack(spacing: 2) {
                    Image(systemName: kind.icon)
                        .font(.system(size: 11))
                        .foregroundStyle(total == 0 ? Claude.textMuted : Claude.orange)
                    Text("\(total > 0 ? "+" : "")\(total)")
                        .font(ClaudeFont.mono(10, weight: .semibold))
                        .foregroundStyle(Claude.textPrimary)
                    Text(kind.label)
                        .font(ClaudeFont.label(9))
                        .foregroundStyle(Claude.textMuted)
                }
                .frame(maxWidth: .infinity)
            }
        }
        .padding(.vertical, 6)
        .padding(.horizontal, 8)
        .background(Claude.surfaceAlt)
        .clipShape(RoundedRectangle(cornerRadius: 8))
    }

    @ViewBuilder
    private func eventRow(_ event: XPEvent) -> some View {
        HStack(spacing: 10) {
            Image(systemName: event.kind.icon)
                .font(.system(size: 12))
                .foregroundStyle(event.amount < 0 ? Color.red : Claude.orange)
                .frame(width: 18)
            VStack(alignment: .leading, spacing: 1) {
                Text(event.detail)
                    .font(ClaudeFont.body(12))
                    .foregroundStyle(Claude.textPrimary)
                    .lineLimit(1)
                Text(relative(event.timestamp))
                    .font(ClaudeFont.mono(10))
                    .foregroundStyle(Claude.textMuted)
            }
            Spacer()
            Text("\(event.amount > 0 ? "+" : "")\(event.amount)")
                .font(ClaudeFont.mono(12, weight: .semibold))
                .foregroundStyle(event.amount < 0 ? Color.red : Claude.orange)
            Text(event.isPetXP ? "PET" : "TR")
                .font(.system(size: 8, weight: .bold))
                .foregroundStyle(.white)
                .padding(.horizontal, 4).padding(.vertical, 1)
                .background(Capsule().fill(event.isPetXP ? Claude.orange : Color.purple))
        }
    }

    private func relative(_ d: Date) -> String {
        let f = RelativeDateTimeFormatter()
        f.unitsStyle = .abbreviated
        f.locale = Locale(identifier: "vi_VN")
        return f.localizedString(for: d, relativeTo: Date())
    }
}
