// Pixel sprite pet — 1 frame idle PNG, animation đến từ SwiftUI effects
// (bounce/wiggle/rotate/scale) thay vì frame-by-frame swap.
//
// Pack Kenney pixel-platformer không có walk animation thực sự (27 sprite
// đều static), nên dùng state effects để tạo "life":
//   happy   → bounce nhẹ
//   excited → bounce mạnh
//   worried → wiggle rotate ±5°
//   dizzy   → lắc nhẹ ±10° (KHÔNG xoay 360° để đỡ chóng mặt)
//   sleepy  → static + scale 0.95 (thở)
//
// Phase 3 (v0.2.2): Thêm level-based visual layers (tier system).
// Tier enum quyết định layers nào được render — halo, sparkle, headwear, tint.
// SF Symbols + SwiftUI shapes — không cần PNG asset mới.

import SwiftUI
import ClaudeWatchCore

// MARK: - Tier

/// Phân loại visual theo level. Private scope — chỉ dùng trong SpritePet.
private enum Tier: Int, Comparable {
    case baby = 0      // Lv 1-2
    case young = 1     // Lv 3-4 — sparkle
    case adult = 2     // Lv 5-6 — halo (tĩnh) + cap
    case veteran = 3   // Lv 7-8 — halo (quay) + cap + gold tint
    case master = 4    // Lv 9-10 — halo (quay) + crown + gold tint + scale 1.05

    static func from(level: Int) -> Tier {
        switch level {
        case ...2:    return .baby
        case 3...4:   return .young
        case 5...6:   return .adult
        case 7...8:   return .veteran
        default:      return .master   // 9-10+
        }
    }

    static func < (lhs: Tier, rhs: Tier) -> Bool { lhs.rawValue < rhs.rawValue }
}

// MARK: - SpritePet

struct SpritePet: View {
    let state: PetState
    let characterName: String
    /// Level 1-10 — default 1 cho backward-compat call site chưa pass level.
    var level: Int = 1

    // MARK: - Static image cache (P0b perf)

    /// Cache NSImage theo characterName — 28 sprite load 1 lần (~5 MB tổng),
    /// giảm disk I/O và NSImage allocation mỗi animation tick.
    /// nonisolated(unsafe) hợp lệ vì mọi access được bảo vệ bởi cacheLock.
    private nonisolated(unsafe) static var imageCache: [String: NSImage] = [:]
    private static let cacheLock = NSLock()

    // State cho base sprite animations (unchanged từ phase trước)
    @State private var bounce: CGFloat = 0
    @State private var wiggle: Double = 0
    @State private var breathe: CGFloat = 1.0

    // State cho level-based animations
    @State private var sparkleOpacity: Double = 0.3
    @State private var haloRotation: Double = 0.0

    private var tier: Tier { Tier.from(level: level) }

    var body: some View {
        ZStack {
            haloLayer
            baseSprite
                .colorMultiply(goldTint)
            sparkleLayer
            headwearLayer
        }
        .scaleEffect(masterScale)
        .onAppear {
            startBaseAnimations()
            startLevelAnimations()
        }
        .onChange(of: state) { _, _ in startBaseAnimations() }
        .onChange(of: level) { _, _ in startLevelAnimations() }
    }

    // MARK: - Base sprite (unchanged logic)

    @ViewBuilder
    private var baseSprite: some View {
        let raw: some View = Group {
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
        raw
            .scaleEffect(breathe)
            .offset(y: bounce)
            .rotationEffect(.degrees(wiggle))
    }

    // MARK: - Level layers

    /// Halo: RadialGradient bên dưới sprite. Adult = tĩnh, Veteran+ = xoay.
    @ViewBuilder
    private var haloLayer: some View {
        if tier >= .adult {
            Circle()
                .fill(RadialGradient(
                    colors: [Color.yellow.opacity(0.35), .clear],
                    center: .center,
                    startRadius: 5,
                    endRadius: 40
                ))
                .scaleEffect(1.25)
                .rotationEffect(.degrees(tier >= .veteran ? haloRotation : 0))
        }
    }

    /// Sparkle: SF Symbol "sparkles" nhỏ top-right, pulse opacity. Lv 3+.
    @ViewBuilder
    private var sparkleLayer: some View {
        if tier >= .young {
            VStack {
                HStack {
                    Spacer()
                    Image(systemName: "sparkles")
                        .font(.system(size: 10, weight: .light))
                        .foregroundStyle(Color.yellow.opacity(sparkleOpacity))
                        .imageScale(.small)
                }
                Spacer()
            }
        }
    }

    /// Headwear: cap (Lv 5-8) hoặc crown (Lv 9-10), đặt top-center.
    @ViewBuilder
    private var headwearLayer: some View {
        if tier >= .adult {
            VStack {
                // Chọn symbol theo tier
                Image(systemName: tier >= .master ? "crown.fill" : "graduationcap.fill")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(tier >= .master ? Color.yellow : Color(red: 0.6, green: 0.4, blue: 0.1))
                    .shadow(color: .black.opacity(0.25), radius: 1, y: 1)
                Spacer()
            }
        }
    }

    // MARK: - Derived values

    /// Gold tint nhẹ cho Veteran+ — colorMultiply blend mode trên baseSprite.
    private var goldTint: Color {
        tier >= .veteran
            ? Color(red: 1.0, green: 0.97, blue: 0.85)
            : .white   // .white = identity cho colorMultiply
    }

    /// Master tier: sprite lớn hơn 5%.
    private var masterScale: CGFloat {
        tier >= .master ? 1.05 : 1.0
    }

    // MARK: - Animation

    /// Reset + apply base animations tương ứng PetState.
    private func startBaseAnimations() {
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
            // Lắc nhẹ qua lại — không xoay 360° để đỡ chóng mặt.
            withAnimation(.easeInOut(duration: 0.6).repeatForever(autoreverses: true)) {
                wiggle = 10
            }
        case .sleepy:
            withAnimation(.easeInOut(duration: 2.2).repeatForever(autoreverses: true)) {
                breathe = 0.94
            }
        }
    }

    /// Khởi động / restart level-based animations khi level thay đổi.
    private func startLevelAnimations() {
        // Reset trước khi apply animation mới
        sparkleOpacity = 0.3
        haloRotation = 0

        // Sparkle pulse — Lv 3+ (tier >= young)
        if tier >= .young {
            withAnimation(.easeInOut(duration: 1.6).repeatForever(autoreverses: true)) {
                sparkleOpacity = 1.0
            }
        }

        // Halo rotation — Lv 7+ (tier >= veteran)
        if tier >= .veteran {
            withAnimation(.linear(duration: 10).repeatForever(autoreverses: false)) {
                haloRotation = 360
            }
        }
    }

    // MARK: - Asset loading

    /// Load idle.png từ Bundle — thử 2 path (xcodegen folder buildPhase đặt
    /// dưới Contents/Resources/Resources/Sprites/...).
    /// Kết quả được cache trong static dict; lần thứ 2 trở đi không có disk I/O.
    private func loadFromBundle() -> NSImage? {
        Self.cacheLock.lock()
        defer { Self.cacheLock.unlock() }

        // Cache hit — trả về ngay, không init NSImage mới.
        if let cached = Self.imageCache[characterName] { return cached }

        guard let res = Bundle.main.resourcePath else { return nil }
        // Thử path primary trước (xcodegen double-nested Resources).
        let primary = "\(res)/Resources/Sprites/\(characterName)/idle.png"
        var img = NSImage(contentsOfFile: primary)
        // Fallback path nếu build config khác đặt Sprites trực tiếp trong Resources.
        if img == nil {
            let alt = "\(res)/Sprites/\(characterName)/idle.png"
            img = NSImage(contentsOfFile: alt)
        }
        if let img {
            Self.imageCache[characterName] = img
        }
        return img
    }
}
