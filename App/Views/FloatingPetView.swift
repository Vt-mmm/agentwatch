// Pet desktop overlay 96×96 + chat bubble pop-up. Dùng PetMascot scale lên,
// thêm bubble ở trên. Window-level draggable thực hiện ở FloatingPetController
// (NSWindow.isMovableByWindowBackground = true).

import SwiftUI
import ClaudeWatchCore

struct FloatingPetView: View {
    let state: PetState
    let talk: PetTalk?       // optional — nil = không show bubble

    var body: some View {
        VStack(spacing: 4) {
            if let t = talk {
                ChatBubble(talk: t)
                    .transition(.scale(scale: 0.5, anchor: .bottom)
                                    .combined(with: .opacity))
            }
            // Mascot scale up 2.4x (36×36 → ~86). Wrap trong frame để layout
            // ổn định khi bubble xuất hiện/biến mất.
            PetMascot(state: state)
                .scaleEffect(2.4)
                .frame(width: 96, height: 96)
        }
        .padding(8)
        .animation(.spring(response: 0.4, dampingFraction: 0.7), value: talk)
    }
}
