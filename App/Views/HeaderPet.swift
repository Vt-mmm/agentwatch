// Pet 96×96 lớn ở header — không còn floating window, pet ở luôn header cùng
// chat bubble bên trái. ChatBubble dùng lại của FloatingPetView (tail trỏ
// xuống dù layout ngang — vẫn đọc OK vì tail nhỏ).

import SwiftUI
import ClaudeWatchCore

struct HeaderPet: View {
    @Environment(FloatingPetController.self) private var pet
    @Environment(SpriteStore.self) private var sprites

    var body: some View {
        HStack(alignment: .bottom, spacing: 8) {
            if let t = pet.talk {
                ChatBubble(talk: t)
                    .transition(.scale(scale: 0.5, anchor: .trailing)
                                    .combined(with: .opacity))
            }
            SpritePet(state: pet.state, characterName: sprites.currentName)
                .frame(width: 96, height: 96)
                .help(pet.state.caption)
        }
        .animation(.spring(response: 0.4, dampingFraction: 0.7), value: pet.talk)
    }
}
