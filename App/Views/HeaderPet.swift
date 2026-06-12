// Pet inline trong header — small sprite + talk bubble label cạnh "live" pill.
// Đọc state/talk/character từ FloatingPetController + SpriteStore. Talk label
// fade in/out theo controller.talk.

import SwiftUI
import ClaudeWatchCore

struct HeaderPet: View {
    @Environment(FloatingPetController.self) private var pet
    @Environment(SpriteStore.self) private var sprites

    var body: some View {
        HStack(spacing: 6) {
            if let t = pet.talk {
                talkChip(t)
                    .transition(.move(edge: .trailing)
                                    .combined(with: .opacity))
            }
            SpritePet(state: pet.state, characterName: sprites.currentName)
                .frame(width: 28, height: 28)
                .help("\(pet.state.caption)\n(click gear → Hiện desktop pet để pet ra desktop)")
        }
        .animation(.spring(response: 0.35, dampingFraction: 0.7), value: pet.talk)
    }

    /// Compact bubble cho header — không có tail, chỉ chip nhỏ.
    private func talkChip(_ t: PetTalk) -> some View {
        let bg: Color = {
            switch t.tone {
            case .alert:   return .red.opacity(0.9)
            case .warning: return .orange.opacity(0.9)
            default:       return Claude.surfaceAlt
            }
        }()
        let fg: Color = {
            switch t.tone {
            case .alert, .warning: return .white
            default:               return Claude.textPrimary
            }
        }()
        return Text(t.message)
            .font(ClaudeFont.body(11))
            .foregroundStyle(fg)
            .lineLimit(1)
            .truncationMode(.tail)
            .frame(maxWidth: 220)
            .fixedSize(horizontal: true, vertical: false)
            .padding(.horizontal, 8)
            .padding(.vertical, 3)
            .background(bg)
            .clipShape(Capsule())
            .overlay(Capsule().strokeBorder(Claude.border, lineWidth: 0.5))
    }
}
