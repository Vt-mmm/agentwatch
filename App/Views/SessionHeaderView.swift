// Session-level header: project, session id, model family.

import SwiftUI
import ClaudeWatchCore

struct SessionHeaderView: View {
    let stats: SessionStats

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 8) {
                Image(systemName: "circle.grid.cross.fill")
                    .foregroundStyle(Claude.orange)
                Text("Session")
                    .font(ClaudeFont.heading())
                    .foregroundStyle(Claude.textPrimary)
                Spacer()
                Text(stats.sessionId.prefix(8))
                    .font(ClaudeFont.mono(11))
                    .foregroundStyle(Claude.textMuted)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(Claude.surfaceAlt, in: Capsule())
            }
            HStack(spacing: 12) {
                pill(label: "MODEL",  value: stats.model.isEmpty ? "?" : stats.model,
                     mono: true)
                pill(label: "FAMILY", value: stats.modelFamily.rawValue,
                     tint: familyColor)
                if !stats.lastEventAt.isEmpty {
                    pill(label: "LAST EVT",
                         value: TokenFormatter.clockTime(from: stats.lastEventAt),
                         mono: true)
                }
            }
        }
        .claudeCard()
    }

    private func pill(label: String, value: String,
                      tint: Color = Claude.textPrimary,
                      mono: Bool = false) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            SectionLabel(text: label)
            Text(value)
                .font(mono ? ClaudeFont.mono(12) : ClaudeFont.body(13))
                .foregroundStyle(tint)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .background(Claude.surfaceAlt)
        .clipShape(RoundedRectangle(cornerRadius: 8))
    }

    private var familyColor: Color {
        switch stats.modelFamily {
        case .opus:    return Claude.orange
        case .sonnet:  return .blue
        case .haiku:   return Claude.live
        case .fable:   return .purple
        case .unknown: return Claude.textMuted
        }
    }
}
