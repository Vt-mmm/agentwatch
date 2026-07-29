// Pet desktop overlay 96×96 + chat bubble pop-up. Dùng PetMascot scale lên,
// thêm bubble ở trên. Window-level draggable thực hiện ở FloatingPetController
// (NSWindow.isMovableByWindowBackground = true).
//
// Phase 3 (v0.2.2): Thêm level param để SpritePet render visual tier đúng.

import SwiftUI
import ClaudeWatchCore

struct FloatingPetView: View {
    let state: PetState
    let talk: PetTalk?
    let characterName: String   // "char0".."char8" từ SpriteStore
    /// Level hiện tại — sync từ FloatingPetController.level.
    var level: Int = 1

    var body: some View {
        VStack(spacing: 4) {
            if let t = talk {
                ChatBubble(talk: t)
                    .transition(.scale(scale: 0.5, anchor: .bottom)
                                    .combined(with: .opacity))
            }
            // Sprite 24×24 scale lên 96×96 (4x) — pixel-perfect.
            SpritePet(state: state, characterName: characterName, level: level)
                .frame(width: 96, height: 96)
        }
        .padding(8)
        .animation(.spring(response: 0.4, dampingFraction: 0.7), value: talk)
    }
}

struct FloatingUsageSidebarView: View {
    let snapshot: FloatingUsageSnapshot

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            header
            Divider().background(Claude.border)
            metricGrid
            Divider().background(Claude.border)
            detailRows
        }
        .padding(12)
        .frame(width: 236, height: 318, alignment: .topLeading)
        .background(.ultraThinMaterial)
        .overlay(
            RoundedRectangle(cornerRadius: 10)
                .strokeBorder(Claude.border.opacity(0.85), lineWidth: 1)
        )
        .clipShape(RoundedRectangle(cornerRadius: 10))
    }

    private var header: some View {
        HStack(spacing: 8) {
            Circle()
                .fill(snapshot.hasActivity ? Claude.live : Claude.textMuted)
                .frame(width: 8, height: 8)
            VStack(alignment: .leading, spacing: 1) {
                Text("Agent Watch")
                    .font(ClaudeFont.heading(13))
                    .foregroundStyle(Claude.textPrimary)
                Text(snapshot.hasActivity ? "Live usage" : "Idle")
                    .font(ClaudeFont.mono(10))
                    .foregroundStyle(Claude.textMuted)
            }
            Spacer()
            Text(shortTime(snapshot.updatedAt))
                .font(ClaudeFont.mono(10))
                .foregroundStyle(Claude.textMuted)
        }
    }

    private var metricGrid: some View {
        LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: 8) {
            metric("Sessions", "\(snapshot.activeSessions)")
            metric("Cost", TokenFormatter.usd(snapshot.totalCost), tint: Claude.orange)
            metric("Tokens", TokenFormatter.compact(snapshot.totalTokens))
            metric("Tools", "\(snapshot.toolCalls)")
        }
    }

    private var detailRows: some View {
        VStack(alignment: .leading, spacing: 7) {
            row("Task", snapshot.latestTask)
            row("Model", snapshot.models)
            row("Thinking", snapshot.thinkingLevel)
            row("Reasoning", TokenFormatter.compact(snapshot.reasoningTokens))
            row("Pi names", "\(snapshot.piNamedSessions)/\(snapshot.piTotalSessions)")
        }
    }

    private func metric(_ label: String, _ value: String,
                        tint: Color = Claude.textPrimary) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(label.uppercased())
                .font(ClaudeFont.label(9))
                .foregroundStyle(Claude.textMuted)
            Text(value)
                .font(ClaudeFont.mono(15, weight: .semibold))
                .foregroundStyle(tint)
                .lineLimit(1)
                .minimumScaleFactor(0.7)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(8)
        .background(Claude.surface.opacity(0.82))
        .clipShape(RoundedRectangle(cornerRadius: 8))
    }

    private func row(_ label: String, _ value: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Text(label)
                .font(ClaudeFont.body(10))
                .foregroundStyle(Claude.textMuted)
                .frame(width: 54, alignment: .leading)
            Text(value)
                .font(ClaudeFont.mono(10, weight: .semibold))
                .foregroundStyle(Claude.textPrimary)
                .lineLimit(1)
                .truncationMode(.middle)
        }
    }

    private func shortTime(_ date: Date) -> String {
        let f = DateFormatter()
        f.dateFormat = "HH:mm:ss"
        f.timeZone = .current
        return f.string(from: date)
    }
}
