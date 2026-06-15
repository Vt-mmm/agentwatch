// Pet ở header — compact toolbar size 56×56, đặt NGAY BÊN TRÁI cụm "live" +
// "Pin folder" (trong ProjectPickerView). Bubble nói chuyện là OVERLAY nổi
// sang BÊN TRÁI pet (tail trỏ phải về phía pet), KHÔNG nằm trong layout flow
// → header KHÔNG đổi chiều cao khi bubble appear/disappear (no reflow).
//
// Vì sao bubble đặt trái: bên phải pet là nút live/pin (control bấm được),
// bên trái là khoảng trống/đường dẫn project → bubble trái đỡ che nút.

import SwiftUI
import ClaudeWatchCore

struct HeaderPet: View {
    @Environment(FloatingPetController.self) private var pet
    @Environment(PetCollectionStore.self) private var petCollection

    /// Footprint cố định của pet trong toolbar — cũng là layout size duy nhất
    /// của view. Bubble vẽ qua .overlay nên không tính vào kích thước này.
    private let petSize: CGFloat = 56
    /// Khoảng hở giữa mép phải bubble (tail) và pet.
    private let bubbleGap: CGFloat = 8

    var body: some View {
        // Layout footprint = đúng 56×56. Overlay không cộng vào kích thước host
        // → chiều cao toolbar giống hệt nhau dù pet.talk nil hay không (zero reflow).
        SpritePet(
            state: pet.state,
            characterName: petCollection.selectedId,
            level: petCollection.pets[petCollection.selectedId]?.level ?? 1
        )
        .frame(width: petSize, height: petSize)
            .help(pet.state.caption)
            .overlay(alignment: .trailing) {
                if let t = pet.talk {
                    ChatBubble(talk: t, tailDirection: .trailing)
                        .fixedSize()                          // bubble tự co theo nội dung
                        .offset(x: -(petSize + bubbleGap))    // đẩy hẳn sang TRÁI pet
                        .allowsHitTesting(false)              // không chặn click control bên dưới
                        .transition(.scale(scale: 0.6, anchor: .trailing)
                                        .combined(with: .opacity))
                }
            }
            // Vẽ trên các sibling để shadow bubble không bị control kế bên che.
            .zIndex(1)
            .animation(.spring(response: 0.4, dampingFraction: 0.7), value: pet.talk)
    }
}
