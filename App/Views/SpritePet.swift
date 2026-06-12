// Pixel sprite pet — load PNG từ bundle, cycle frame theo PetState.
// Pixel-perfect rendering nhờ .interpolation(.none) — sprite 24×24 scale up
// không bị mờ.
//
// Animation strategy:
//   sleepy   → 1 frame idle, no swap
//   happy    → 2 frames idle ↔ walk1 (slow breathe ~1Hz)
//   excited  → 3 frames cycle (idle → walk1 → walk2) 6Hz
//   worried  → 2 frames idle ↔ walk2 (lắc) 3Hz
//   dizzy    → 3 frames cycle nhanh + rotation
//
// Mỗi character (char0..char8) có 3 frame PNG: idle/walk1/walk2 từ Kenney
// pixel-platformer pack CC0.

import SwiftUI
import ClaudeWatchCore

struct SpritePet: View {
    let state: PetState
    let characterName: String

    @State private var frameIndex: Int = 0
    @State private var wiggle: Double = 0

    /// Frames sẽ cycle theo state.
    private var frames: [String] {
        switch state {
        case .sleepy:  return ["idle"]
        case .happy:   return ["idle", "walk1"]
        case .excited: return ["idle", "walk1", "walk2"]
        case .worried: return ["idle", "walk2"]
        case .dizzy:   return ["idle", "walk1", "walk2"]
        }
    }

    /// Tốc độ animation theo state (frames per second).
    private var fps: Double {
        switch state {
        case .sleepy:  return 0      // static
        case .happy:   return 1.2
        case .excited: return 6
        case .worried: return 3
        case .dizzy:   return 8
        }
    }

    var body: some View {
        sprite
            .rotationEffect(.degrees(wiggle))
            .onAppear { startTimer(); startWiggle() }
            .onChange(of: state) { _, _ in
                frameIndex = 0; startWiggle()
            }
            .onChange(of: characterName) { _, _ in frameIndex = 0 }
    }

    @ViewBuilder
    private var sprite: some View {
        let frameName = frames[frameIndex % frames.count]
        if let nsImage = NSImage(named: "Sprites/\(characterName)/\(frameName)") ??
            loadFromBundle(name: frameName) {
            Image(nsImage: nsImage)
                .resizable()
                .interpolation(.none)        // pixel-perfect, không blur
                .aspectRatio(contentMode: .fit)
        } else {
            // Fallback nếu thiếu asset — placeholder cho visible debug.
            Image(systemName: "questionmark.square")
                .resizable()
                .foregroundStyle(.red)
        }
    }

    /// Bundle.main lookup — Resources folder type: folder bundle theo path,
    /// nên cần resourcePath join thủ công.
    private func loadFromBundle(name: String) -> NSImage? {
        guard let res = Bundle.main.resourcePath else { return nil }
        let path = "\(res)/Resources/Sprites/\(characterName)/\(name).png"
        // Try cả 2 path (xcodegen có thể flatten Resources/ hoặc giữ nguyên).
        if let img = NSImage(contentsOfFile: path) { return img }
        let alt = "\(res)/Sprites/\(characterName)/\(name).png"
        return NSImage(contentsOfFile: alt)
    }

    private func startTimer() {
        guard fps > 0 else { return }
        let interval = UInt64(1_000_000_000.0 / fps)
        Task { @MainActor in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: interval)
                frameIndex += 1
            }
        }
    }

    private func startWiggle() {
        wiggle = 0
        switch state {
        case .worried:
            withAnimation(.easeInOut(duration: 0.5).repeatForever(autoreverses: true)) {
                wiggle = 4
            }
        case .dizzy:
            withAnimation(.linear(duration: 2).repeatForever(autoreverses: false)) {
                wiggle = 360
            }
        default: break
        }
    }
}
