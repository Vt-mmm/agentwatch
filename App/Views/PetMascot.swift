// Mascot pet 36×36 ở top-bar — phản ánh PetState (sleepy/happy/excited/worried/dizzy).
// Vẽ bằng SwiftUI shapes thuần, không Lottie/asset → ít dependency, animate mượt.

import SwiftUI
import ClaudeWatchCore

struct PetMascot: View {
    let state: PetState

    @State private var blink: Bool = false
    @State private var bounce: CGFloat = 0
    @State private var wiggle: Double = 0

    var body: some View {
        ZStack {
            // Body — rounded square màu Claude orange với highlight.
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(bodyColor)
                .overlay(
                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .strokeBorder(bodyColor.opacity(0.5), lineWidth: 1)
                )
            // Tai trái & phải
            Triangle()
                .fill(bodyColor)
                .frame(width: 8, height: 8)
                .offset(x: -10, y: -16)
            Triangle()
                .fill(bodyColor)
                .frame(width: 8, height: 8)
                .offset(x: 10, y: -16)
            // Mắt
            HStack(spacing: 6) {
                eye(left: true)
                eye(left: false)
            }
            .offset(y: -2)
            // Miệng
            mouth
                .offset(y: 8)
        }
        .frame(width: 36, height: 36)
        .offset(y: bounce)
        .rotationEffect(.degrees(wiggle))
        .animation(.spring(response: 0.4, dampingFraction: 0.5), value: state)
        .help(state.caption)
        .onAppear { startTimers() }
        .onChange(of: state) { _, _ in restartAnimations() }
    }

    /// Body color — happy/excited Claude.orange, worried/dizzy slight desaturate.
    private var bodyColor: Color {
        switch state {
        case .happy, .excited: return Claude.orange
        case .sleepy:          return Claude.orange.opacity(0.55)
        case .worried:         return .orange
        case .dizzy:           return .red.opacity(0.85)
        }
    }

    @ViewBuilder
    private func eye(left: Bool) -> some View {
        let isClosed = blink || state == .sleepy
        ZStack {
            if isClosed {
                // Mắt nhắm — gạch ngang
                Capsule().fill(Color.white).frame(width: 6, height: 1.5)
            } else if state == .dizzy {
                // Mắt xoắn @
                Image(systemName: "swirl.circle")
                    .font(.system(size: 8, weight: .bold))
                    .foregroundStyle(.white)
            } else if state == .excited {
                // Star eyes
                Image(systemName: "star.fill")
                    .font(.system(size: 7))
                    .foregroundStyle(.yellow)
            } else {
                Circle().fill(Color.white).frame(width: 6, height: 6)
                Circle().fill(Color.black).frame(width: 3, height: 3)
                    .offset(x: state == .worried ? (left ? -0.5 : 0.5) : 0)
            }
        }
        .frame(width: 8, height: 8)
    }

    @ViewBuilder
    private var mouth: some View {
        switch state {
        case .happy:
            Path { p in
                p.move(to: CGPoint(x: 0, y: 0))
                p.addQuadCurve(to: CGPoint(x: 10, y: 0),
                               control: CGPoint(x: 5, y: 4))
            }
            .stroke(Color.white, lineWidth: 1.4)
            .frame(width: 10, height: 4)
        case .excited:
            Circle().fill(Color.white).frame(width: 6, height: 5)
        case .sleepy:
            Capsule().fill(Color.white).frame(width: 6, height: 1.2)
        case .worried:
            Path { p in
                p.move(to: CGPoint(x: 0, y: 4))
                p.addQuadCurve(to: CGPoint(x: 10, y: 4),
                               control: CGPoint(x: 5, y: 0))
            }
            .stroke(Color.white, lineWidth: 1.4)
            .frame(width: 10, height: 4)
        case .dizzy:
            Path { p in
                p.move(to: CGPoint(x: 0, y: 2))
                p.addLine(to: CGPoint(x: 3, y: 4))
                p.addLine(to: CGPoint(x: 6, y: 2))
                p.addLine(to: CGPoint(x: 9, y: 4))
            }
            .stroke(Color.white, lineWidth: 1.4)
            .frame(width: 10, height: 4)
        }
    }

    private func startTimers() {
        // Blink mỗi 3s (skip nếu sleepy — đã nhắm sẵn).
        Task { @MainActor in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 3_000_000_000)
                guard state != .sleepy else { continue }
                withAnimation(.easeInOut(duration: 0.12)) { blink = true }
                try? await Task.sleep(nanoseconds: 150_000_000)
                withAnimation(.easeInOut(duration: 0.12)) { blink = false }
            }
        }
        restartAnimations()
    }

    /// Animation idle theo state. Restart khi state đổi.
    private func restartAnimations() {
        bounce = 0; wiggle = 0
        switch state {
        case .happy:
            withAnimation(.easeInOut(duration: 1.2).repeatForever(autoreverses: true)) {
                bounce = -2
            }
        case .excited:
            withAnimation(.spring(response: 0.3, dampingFraction: 0.4).repeatForever(autoreverses: true)) {
                bounce = -4
            }
        case .worried:
            withAnimation(.easeInOut(duration: 0.6).repeatForever(autoreverses: true)) {
                wiggle = 4
            }
        case .dizzy:
            withAnimation(.linear(duration: 2).repeatForever(autoreverses: false)) {
                wiggle = 360
            }
        case .sleepy:
            withAnimation(.easeInOut(duration: 2.5).repeatForever(autoreverses: true)) {
                bounce = -1
            }
        }
    }
}

/// Tai mèo — tam giác cho ear.
private struct Triangle: Shape {
    func path(in rect: CGRect) -> Path {
        var p = Path()
        p.move(to: CGPoint(x: rect.midX, y: rect.minY))
        p.addLine(to: CGPoint(x: rect.minX, y: rect.maxY))
        p.addLine(to: CGPoint(x: rect.maxX, y: rect.maxY))
        p.closeSubpath()
        return p
    }
}
