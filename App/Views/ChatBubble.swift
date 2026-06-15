// Speech bubble bong bóng thoại. Tail có thể trỏ XUỐNG (mặc định, dùng cho
// floating pet ở desktop — bubble nằm TRÊN pet) hoặc trỏ SANG PHẢI (dùng cho
// header pet — bubble nằm BÊN TRÁI pet, tail trỏ về phía pet bên phải).

import SwiftUI
import ClaudeWatchCore

struct ChatBubble: View {
    let talk: PetTalk
    /// Hướng tail trỏ về phía pet. `.down` = pet ở dưới (floating desktop),
    /// `.trailing` = pet ở bên phải (header toolbar). Default `.down` giữ
    /// nguyên hành vi cũ cho FloatingPetView (không cần sửa call-site đó).
    var tailDirection: TailDirection = .down

    enum TailDirection { case down, trailing, leading }

    private var bg: Color {
        switch talk.tone {
        case .greet, .working, .done, .idle: return Color.white
        case .cheer:   return Color(red: 1.0, green: 0.93, blue: 0.6) // soft pastel yellow
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

    /// Khối text bubble dùng chung cho cả 2 hướng tail.
    private var bubbleBody: some View {
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
    }

    private var tail: some View {
        BubbleTail(direction: tailDirection)
            .fill(bg)
            .overlay(
                BubbleTail(direction: tailDirection)
                    .stroke(Color.black.opacity(0.15), lineWidth: 1)
            )
    }

    var body: some View {
        switch tailDirection {
        case .down:
            // Bubble TRÊN pet — tail trỏ xuống, đặt lệch phải (về phía pet).
            VStack(alignment: .trailing, spacing: 0) {
                bubbleBody
                tail
                    .frame(width: 12, height: 7)
                    .padding(.trailing, 16)
            }
            .fixedSize(horizontal: false, vertical: true)
            .frame(maxWidth: 220)
        case .trailing:
            // Bubble BÊN TRÁI pet — tail trỏ sang phải, canh giữa theo chiều dọc.
            HStack(alignment: .center, spacing: 0) {
                bubbleBody
                tail
                    .frame(width: 7, height: 12)
            }
            .fixedSize(horizontal: false, vertical: true)
            .frame(maxWidth: 220)
        case .leading:
            // Bubble BÊN PHẢI pet — tail trỏ sang trái, canh giữa theo chiều dọc.
            HStack(alignment: .center, spacing: 0) {
                tail
                    .frame(width: 7, height: 12)
                bubbleBody
            }
            .fixedSize(horizontal: false, vertical: true)
            .frame(maxWidth: 220)
        }
    }
}

private struct BubbleTail: Shape {
    let direction: ChatBubble.TailDirection

    func path(in rect: CGRect) -> Path {
        var p = Path()
        switch direction {
        case .down:
            // Tam giác đáy ở trên, đỉnh xuống dưới — trỏ thẳng xuống pet.
            p.move(to: CGPoint(x: rect.minX, y: rect.minY))
            p.addLine(to: CGPoint(x: rect.midX, y: rect.maxY))
            p.addLine(to: CGPoint(x: rect.maxX, y: rect.minY))
        case .trailing:
            // Đáy bên trái, đỉnh bên phải — trỏ sang pet ở bên phải.
            p.move(to: CGPoint(x: rect.minX, y: rect.minY))
            p.addLine(to: CGPoint(x: rect.maxX, y: rect.midY))
            p.addLine(to: CGPoint(x: rect.minX, y: rect.maxY))
        case .leading:
            // Đáy bên phải, đỉnh bên trái — trỏ sang pet ở bên trái.
            p.move(to: CGPoint(x: rect.maxX, y: rect.minY))
            p.addLine(to: CGPoint(x: rect.minX, y: rect.midY))
            p.addLine(to: CGPoint(x: rect.maxX, y: rect.maxY))
        }
        p.closeSubpath()
        return p
    }
}
