// Hero views: loading state + empty scope state — hiển thị thay thế cards khi chưa có data.
// Dependency direction: extension on CoachingReportView, no outward dependencies.

import SwiftUI
import ClaudeWatchCore

extension CoachingReportView {

    // MARK: - Loading hero

    /// Hero hiển thị khi đang load lần đầu — KHÔNG để render cards với số 0
    /// gây hiểu nhầm. Stable layout (cùng vị trí với empty hero) để không
    /// nhảy khi swap state.
    var coachingLoadingHero: some View {
        VStack(spacing: 14) {
            ProgressView()
                .controlSize(.large)
                .frame(width: 110, height: 110)
            Text("Đang tải coaching data…")
                .font(ClaudeFont.body(13))
                .foregroundStyle(Claude.textMuted)
        }
        .frame(maxWidth: .infinity)
        .padding(40)
        .claudeCard()
    }

    // MARK: - Empty hero

    /// Hero hiển thị khi không có session/record nào trong scope hiện tại.
    /// Friendly hint user đổi scope thay vì để màn hình toàn số 0.
    var coachingEmptyHero: some View {
        VStack(spacing: 14) {
            ZStack {
                Circle()
                    .fill(Claude.orangeSoft)
                    .frame(width: 110, height: 110)
                Image(systemName: "moon.zzz.fill")
                    .font(.system(size: 44, weight: .medium))
                    .foregroundStyle(Claude.orange)
            }
            VStack(spacing: 6) {
                Text("Chưa có session nào")
                    .font(ClaudeFont.display(20))
                    .foregroundStyle(Claude.textPrimary)
                Text("Khoảng \(scopeRangeLabel) chưa có hoạt động agent nào.\nMở Claude, Codex hoặc PiAgent để Agent Watch bắt đầu theo dõi.")
                    .font(ClaudeFont.body(13))
                    .foregroundStyle(Claude.textMuted)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
            }
            HStack(spacing: 8) {
                Button("Hôm nay") {
                    scope = .day; anchor = Date()
                }
                .buttonStyle(.bordered)
                Button("7 ngày") {
                    scope = .week; anchor = Date()
                }
                .buttonStyle(.bordered)
                Button("30 ngày") {
                    scope = .month; anchor = Date()
                }
                .buttonStyle(.borderedProminent)
                .tint(Claude.orange)
            }
        }
        .frame(maxWidth: .infinity)
        .padding(40)
        .claudeCard()
    }
}
