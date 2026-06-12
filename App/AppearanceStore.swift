// Theme toggle: system / light / dark. Persist qua UserDefaults.
// Bind vào WindowGroup + MenuBarExtra qua .preferredColorScheme(...).

import SwiftUI
import Observation

enum ThemeMode: String, CaseIterable, Identifiable {
    case system, light, dark
    var id: String { rawValue }

    var label: String {
        switch self {
        case .system: return "Auto"
        case .light:  return "Sáng"
        case .dark:   return "Tối"
        }
    }

    var icon: String {
        switch self {
        case .system: return "circle.lefthalf.filled"
        case .light:  return "sun.max.fill"
        case .dark:   return "moon.fill"
        }
    }

    /// `nil` = inherit system. SwiftUI sẽ xoá override.
    var colorScheme: ColorScheme? {
        switch self {
        case .system: return nil
        case .light:  return .light
        case .dark:   return .dark
        }
    }
}

@Observable
@MainActor
final class AppearanceStore {
    private let key = "themeMode"

    var mode: ThemeMode {
        didSet { UserDefaults.standard.set(mode.rawValue, forKey: key) }
    }

    init() {
        let stored = UserDefaults.standard.string(forKey: key)
        self.mode = ThemeMode(rawValue: stored ?? "") ?? .system
    }
}
