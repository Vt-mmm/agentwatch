// Persists the user's project mode across launches: either pinned to a folder
// or following the most-recently-active session across all projects.

import Foundation
import Observation

@Observable
@MainActor
final class ProjectStore {
    private let pinKey = "pinnedProjectPath"
    private let followKey = "followLatest"

    var pinnedFolder: URL? {
        didSet { persist() }
    }

    /// Default true on first launch — anh mở app là thấy ngay session đang chạy.
    var followLatest: Bool {
        didSet { persist() }
    }

    init() {
        let defaults = UserDefaults.standard
        if let path = defaults.string(forKey: pinKey),
           !path.isEmpty,
           FileManager.default.fileExists(atPath: path) {
            pinnedFolder = URL(fileURLWithPath: path)
        } else {
            pinnedFolder = nil
        }
        if defaults.object(forKey: followKey) == nil {
            followLatest = true  // first-launch default
        } else {
            followLatest = defaults.bool(forKey: followKey)
        }
    }

    func pinFolder(_ url: URL) {
        pinnedFolder = url
        followLatest = false
    }

    func switchToFollowLatest() {
        pinnedFolder = nil
        followLatest = true
    }

    private func persist() {
        let defaults = UserDefaults.standard
        defaults.set(pinnedFolder?.path, forKey: pinKey)
        defaults.set(followLatest, forKey: followKey)
    }
}
