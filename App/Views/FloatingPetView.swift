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
