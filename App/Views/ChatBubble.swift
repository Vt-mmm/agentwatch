// Speech bubble bong bóng thoại — hiện trên đầu pet với tail nhọn xuống.
// Auto-dismiss sau N giây, transition mượt từ scale+opacity.

import SwiftUI
import ClaudeWatchCore

struct ChatBubble: View {
    let talk: PetTalk

    private var bg: Color {
        switch talk.tone {
        case .greet, .working, .done, .idle: return Color.white
        case .warning: return Color.yellow.opacity(0.95)
        case .alert:   return Color.red.opacity(0.95)
        }
    }

    private var fg: Color {
        switch talk.tone {
        case .alert, .warning: return Color.white
        default:               return Color.black
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            Text(talk.message)
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(fg)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
                .background(bg)
                .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                .overlay(
                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                        .strokeBorder(Color.black.opacity(0.15), lineWidth: 1)
                )
                .shadow(color: .black.opacity(0.2), radius: 4, y: 2)
            // Đuôi bubble nhọn xuống dưới
            BubbleTail()
                .fill(bg)
                .frame(width: 12, height: 6)
                .overlay(
                    BubbleTail()
                        .stroke(Color.black.opacity(0.15), lineWidth: 1)
                )
        }
        .fixedSize(horizontal: false, vertical: true)
        .frame(maxWidth: 220)
    }
}

private struct BubbleTail: Shape {
    func path(in rect: CGRect) -> Path {
        var p = Path()
        p.move(to: CGPoint(x: rect.minX, y: rect.minY))
        p.addLine(to: CGPoint(x: rect.midX, y: rect.maxY))
        p.addLine(to: CGPoint(x: rect.maxX, y: rect.minY))
        p.closeSubpath()
        return p
    }
}
