// Quản lý lựa chọn nhân vật sprite. Persist qua UserDefaults.
// Sprites bundle vào app từ App/Resources/Sprites/charN/{idle,walk1,walk2}.png
// (Kenney pixel-platformer pack, CC0 — public domain, free commercial use).

import Foundation
import Observation

@Observable
@MainActor
final class SpriteStore {
    static let count = 9   // char0..char8

    /// Index character đang chọn. Persist; default = 1 (orange dude).
    var selected: Int = 1 {
        didSet { UserDefaults.standard.set(selected, forKey: "SpriteStore.selected") }
    }

    init() {
        let raw = UserDefaults.standard.object(forKey: "SpriteStore.selected") as? Int
        self.selected = raw.map { max(0, min($0, Self.count - 1)) } ?? 1
    }

    var currentName: String { "char\(selected)" }

    /// Display label cho dropdown — tạm gán tên theo màu/style trực quan.
    static let names: [String] = [
        "Đỏ", "Cam", "Vàng", "Lục", "Lam", "Tím", "Hồng", "Ninja", "Đặc biệt"
    ]
}
