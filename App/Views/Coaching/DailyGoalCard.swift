// Daily goal card — borrowed from Duolingo daily goal pattern.
// Hiển thị progress hôm nay vs user-configured target.
// 2 metric chính: prompts ≥3★ và sessions không-outlier.

import SwiftUI
import ClaudeWatchCore

struct DailyGoalCard: View {
    let records: [PromptRecord]
    let sessions: [SessionSummary]
    let outlierIds: Set<String>
    let agentLoopIds: Set<String>

    @AppStorage("dailyGoal.promptStars") private var promptTarget: Int = 5
    @AppStorage("dailyGoal.cleanSessions") private var sessionTarget: Int = 3

    private var todayPromptCount: Int {
        let start = Calendar.current.startOfDay(for: Date())
        return records.filter { $0.timestamp >= start && $0.score.stars >= 3 }.count
    }

    private var todayCleanSessionCount: Int {
        let start = Calendar.current.startOfDay(for: Date())
        return sessions.filter { s in
            guard let t = s.firstTimestamp, t >= start else { return false }
            return !outlierIds.contains(s.id) && !agentLoopIds.contains(s.id)
        }.count
    }

    private var promptComplete: Bool { todayPromptCount >= promptTarget }
    private var sessionComplete: Bool { todayCleanSessionCount >= sessionTarget }
    private var allComplete: Bool { promptComplete && sessionComplete }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 6) {
                Image(systemName: allComplete ? "checkmark.seal.fill" : "target")
                    .foregroundStyle(allComplete ? .green : Claude.orange)
                SectionLabel(text: allComplete ? "Hoàn thành mục tiêu hôm nay! 🎉" : "Mục tiêu hôm nay")
                Spacer()
                NumericStepperRow(promptTarget: $promptTarget, sessionTarget: $sessionTarget)
            }

            goalRow(
                icon: "star.fill",
                label: "Prompt ≥3★",
                current: todayPromptCount,
                target: promptTarget,
                color: .yellow
            )
            goalRow(
                icon: "checkmark.circle.fill",
                label: "Session không outlier",
                current: todayCleanSessionCount,
                target: sessionTarget,
                color: .green
            )
        }
        .claudeCard()
    }

    @ViewBuilder
    private func goalRow(icon: String, label: String, current: Int, target: Int, color: Color) -> some View {
        let ratio = target > 0 ? min(1.0, Double(current) / Double(target)) : 1.0
        let done = current >= target
        HStack(spacing: 10) {
            Image(systemName: icon)
                .font(.system(size: 11))
                .foregroundStyle(done ? .green : color)
                .frame(width: 16)
            VStack(alignment: .leading, spacing: 3) {
                HStack {
                    Text(label)
                        .font(ClaudeFont.body(12))
                        .foregroundStyle(Claude.textPrimary)
                    Spacer()
                    Text("\(current)/\(target)")
                        .font(ClaudeFont.mono(11, weight: .semibold))
                        .foregroundStyle(done ? .green : Claude.textPrimary)
                }
                GeometryReader { geo in
                    ZStack(alignment: .leading) {
                        RoundedRectangle(cornerRadius: 3)
                            .fill(Claude.surfaceAlt)
                        RoundedRectangle(cornerRadius: 3)
                            .fill(done ? Color.green : color)
                            .frame(width: geo.size.width * ratio)
                    }
                }
                .frame(height: 6)
            }
        }
    }
}

/// Compact stepper editor cho 2 target — popover khi click "Edit".
private struct NumericStepperRow: View {
    @Binding var promptTarget: Int
    @Binding var sessionTarget: Int
    @State private var showEditor = false

    var body: some View {
        Button { showEditor.toggle() } label: {
            Image(systemName: "slider.horizontal.3")
                .font(.system(size: 11))
                .foregroundStyle(Claude.textMuted)
        }
        .buttonStyle(.plain)
        .help("Điều chỉnh target")
        .popover(isPresented: $showEditor, arrowEdge: .top) {
            VStack(alignment: .leading, spacing: 10) {
                Text("Target hàng ngày")
                    .font(ClaudeFont.heading(13))
                Stepper("Prompt ≥3★: \(promptTarget)", value: $promptTarget, in: 1...30)
                    .font(ClaudeFont.body(11))
                Stepper("Clean session: \(sessionTarget)", value: $sessionTarget, in: 1...20)
                    .font(ClaudeFont.body(11))
            }
            .padding(12)
            .frame(width: 220)
        }
    }
}
