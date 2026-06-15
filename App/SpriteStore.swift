// DEPRECATED (v0.2.0): Dùng PetCollectionStore cho code mới.
// Giữ class này để tránh break @Environment injection ở những ref còn sót.
// Sẽ xóa hẳn ở phase 3 sau khi grep confirm không còn consumer nào.
//
// Quản lý lựa chọn nhân vật sprite. Persist qua UserDefaults.
// 27 character riêng biệt từ Kenney pixel-platformer pack (CC0 public domain).
// Mỗi character chỉ có 1 idle frame — animation đến từ wiggle/rotate state-driven
// thay vì frame-by-frame walk cycle (pack này không có walk animation thật).

import Foundation
import Observation

@Observable
@MainActor
final class SpriteStore {
    static let count = 27   // char00..char26

    /// Index character đang chọn. Persist; default = 1.
    var selected: Int = 1 {
        didSet { UserDefaults.standard.set(selected, forKey: "SpriteStore.selected") }
    }

    init() {
        let raw = UserDefaults.standard.object(forKey: "SpriteStore.selected") as? Int
        self.selected = raw.map { max(0, min($0, Self.count - 1)) } ?? 1
    }

    /// Folder name: char00, char01, ..., char26 (2-digit padded).
    var currentName: String { String(format: "char%02d", selected) }

    /// Label hiển thị trong picker.
    static func displayName(_ idx: Int) -> String {
        "Pet #\(String(format: "%02d", idx))"
    }
}
