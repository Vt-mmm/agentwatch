// Pixel sprite pet — 1 frame idle PNG, animation đến từ SwiftUI effects
// (bounce/wiggle/rotate/scale) thay vì frame-by-frame swap.
//
// Pack Kenney pixel-platformer không có walk animation thực sự (27 sprite
// đều static), nên dùng state effects để tạo "life":
//   happy   → bounce nhẹ
//   excited → bounce mạnh
//   worried → wiggle rotate ±5°
//   dizzy   → spin 360° liên tục
//   sleepy  → static + scale 0.95 (thở)

import SwiftUI
import ClaudeWatchCore

struct SpritePet: View {
    let state: PetState
    let characterName: String

    @State private var bounce: CGFloat = 0
    @State private var wiggle: Double = 0
    @State private var spin: Double = 0
    @State private var breathe: CGFloat = 1.0

    var body: some View {
        sprite
            .scaleEffect(breathe)
            .offset(y: bounce)
            .rotationEffect(.degrees(state == .dizzy ? spin : wiggle))
            .onAppear { startAnimations() }
            .onChange(of: state) { _, _ in startAnimations() }
    }

    @ViewBuilder
    private var sprite: some View {
        if let nsImage = loadFromBundle() {
            Image(nsImage: nsImage)
                .resizable()
                .interpolation(.none)        // pixel-perfect
                .aspectRatio(contentMode: .fit)
        } else {
            Image(systemName: "questionmark.square")
                .resizable()
                .foregroundStyle(.red)
        }
    }

    /// Resources/Sprites/charNN/idle.png (xcodegen folder buildPhase đặt dưới
    /// Contents/Resources/Resources/Sprites/...).
    private func loadFromBundle() -> NSImage? {
        guard let res = Bundle.main.resourcePath else { return nil }
        let primary = "\(res)/Resources/Sprites/\(characterName)/idle.png"
        if let img = NSImage(contentsOfFile: primary) { return img }
        let alt = "\(res)/Sprites/\(characterName)/idle.png"
        return NSImage(contentsOfFile: alt)
    }

    /// Reset + apply animation tương ứng state. Cancel implicit qua việc set
    /// lại từ đầu (SwiftUI tự diff).
    private func startAnimations() {
        bounce = 0; wiggle = 0; breathe = 1.0
        switch state {
        case .happy:
            withAnimation(.easeInOut(duration: 0.9).repeatForever(autoreverses: true)) {
                bounce = -3
            }
        case .excited:
            withAnimation(.spring(response: 0.25, dampingFraction: 0.4)
                            .repeatForever(autoreverses: true)) {
                bounce = -6
            }
        case .worried:
            withAnimation(.easeInOut(duration: 0.4).repeatForever(autoreverses: true)) {
                wiggle = 5
            }
        case .dizzy:
            withAnimation(.linear(duration: 1.8).repeatForever(autoreverses: false)) {
                spin = 360
            }
        case .sleepy:
            withAnimation(.easeInOut(duration: 2.2).repeatForever(autoreverses: true)) {
                breathe = 0.94
            }
        }
    }
}
