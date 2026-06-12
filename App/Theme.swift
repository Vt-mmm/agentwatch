// Claude-inspired color tokens, typography helpers, and card modifier.
// Colors track the warm "Linen / Espresso / Crail" palette Anthropic uses
// across claude.ai. Adaptive light/dark via NSColor dynamic providers.

import SwiftUI
import AppKit

enum Claude {

    // MARK: - Brand (mode-independent)

    /// Anthropic warm orange (~#CC785C, "Crail").
    static let orange = Color(.sRGB, red: 204/255, green: 120/255, blue:  92/255, opacity: 1)
    static let orangeSoft = Color(.sRGB, red: 204/255, green: 120/255, blue:  92/255, opacity: 0.18)

    /// Subagent-status accents.
    static let live = Color(.sRGB, red:  94/255, green: 139/255, blue:  94/255, opacity: 1) // muted moss
    static let done = Color(.sRGB, red: 168/255, green: 163/255, blue: 154/255, opacity: 1)

    /// Status chip palette inspired by petdex's OKLCH chip scale —
    /// pairs a soft tint with a deep ink so labels always read clean.
    enum Chip {
        static let warningBg = Color(.sRGB, red: 254/255, green: 243/255, blue: 199/255, opacity: 1)
        static let warningFg = Color(.sRGB, red: 120/255, green:  63/255, blue:  11/255, opacity: 1)
        static let successBg = Color(.sRGB, red: 209/255, green: 250/255, blue: 229/255, opacity: 1)
        static let successFg = Color(.sRGB, red:   6/255, green:  78/255, blue:  59/255, opacity: 1)
        static let dangerBg  = Color(.sRGB, red: 254/255, green: 205/255, blue: 211/255, opacity: 1)
        static let dangerFg  = Color(.sRGB, red: 136/255, green:  19/255, blue:  55/255, opacity: 1)
        static let infoBg    = Color(.sRGB, red: 219/255, green: 234/255, blue: 254/255, opacity: 1)
        static let infoFg    = Color(.sRGB, red:  30/255, green:  58/255, blue: 138/255, opacity: 1)
    }

    /// Subtle warm wash for the main window background.
    static var backgroundGradient: LinearGradient {
        LinearGradient(
            colors: [background, surfaceAlt],
            startPoint: .top,
            endPoint: .bottom
        )
    }

    // MARK: - Adaptive

    static let background  = dynamic(light: (250, 249, 245), dark: ( 38,  38,  36))
    static let surface     = dynamic(light: (255, 255, 252), dark: ( 48,  48,  46))
    static let surfaceAlt  = dynamic(light: (247, 244, 236), dark: ( 56,  56,  54))
    static let border      = dynamic(light: (229, 225, 216), dark: ( 60,  60,  58))
    static let textPrimary = dynamic(light: ( 61,  57,  41), dark: (231, 229, 220))
    static let textMuted   = dynamic(light: (111, 107,  90), dark: (168, 163, 154))

    private static func dynamic(light: (Int, Int, Int), dark: (Int, Int, Int)) -> Color {
        Color(nsColor: NSColor(name: nil) { appearance in
            let isDark = appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
            let rgb = isDark ? dark : light
            return NSColor(srgbRed: CGFloat(rgb.0) / 255.0,
                           green:    CGFloat(rgb.1) / 255.0,
                           blue:     CGFloat(rgb.2) / 255.0,
                           alpha:    1)
        })
    }
}

// MARK: - Typography

enum ClaudeFont {
    static func display(_ size: CGFloat = 28) -> Font {
        .system(size: size, weight: .semibold, design: .serif)
    }
    static func heading(_ size: CGFloat = 16) -> Font {
        .system(size: size, weight: .semibold, design: .serif)
    }
    static func label(_ size: CGFloat = 11) -> Font {
        .system(size: size, weight: .medium, design: .default)
    }
    static func body(_ size: CGFloat = 13) -> Font {
        .system(size: size, design: .default)
    }
    static func mono(_ size: CGFloat = 13, weight: Font.Weight = .regular) -> Font {
        .system(size: size, weight: weight, design: .monospaced)
    }
}

// MARK: - Card modifier

struct ClaudeCardModifier: ViewModifier {
    var padding: CGFloat = 16
    func body(content: Content) -> some View {
        content
            .padding(padding)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Claude.surface)
            .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .strokeBorder(Claude.border, lineWidth: 1)
            )
    }
}

extension View {
    func claudeCard(padding: CGFloat = 16) -> some View {
        modifier(ClaudeCardModifier(padding: padding))
    }
}

// MARK: - Small reusable bits

struct SectionLabel: View {
    let text: String
    var body: some View {
        Text(text.uppercased())
            .font(ClaudeFont.label(10))
            .tracking(0.8)
            .foregroundStyle(Claude.textMuted)
    }
}
