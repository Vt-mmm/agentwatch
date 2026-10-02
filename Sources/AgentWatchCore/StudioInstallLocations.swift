import Foundation

/// Where npm puts global packages on member Macs. A member's Node setup
/// (nodejs.org installer, Homebrew, nvm, fnm, asdf, mise, Volta or a custom
/// npm prefix) must not decide whether Watch finds Piagent, Pi and Node.
/// Fixed prefixes keep their historical order; version managers follow,
/// newest Node first.
public enum StudioInstallLocations {
    private static let versionManagers: [(root: String, suffix: String)] = [
        (".nvm/versions/node", ""), ("Library/Application Support/fnm/node-versions", "installation"),
        (".local/share/fnm/node-versions", "installation"), (".fnm/node-versions", "installation"),
        (".asdf/installs/nodejs", ""), (".local/share/mise/installs/node", ""), (".volta/tools/image/node", ""),
    ]

    /// npm prefixes of version-managed Node installs, newest version first.
    public static func versionManagedPrefixes(home: URL) -> [URL] {
        var prefixes: [URL] = []
        for manager in versionManagers {
            let root = home.appendingPathComponent(manager.root, isDirectory: true)
            guard let names = try? FileManager.default.contentsOfDirectory(atPath: root.path) else { continue }
            for name in names.filter({ !$0.hasPrefix(".") }).sorted(by: newer) {
                let prefix = root.appendingPathComponent(name, isDirectory: true)
                prefixes.append(manager.suffix.isEmpty ? prefix : prefix.appendingPathComponent(manager.suffix, isDirectory: true))
            }
        }
        return prefixes
    }

    /// npm prefixes members set to avoid sudo, and Volta's per-package image.
    static func userPrefixes(home: URL, package: String) -> [URL] {
        [".npm-global", ".npm-packages", ".volta/tools/image/packages/" + package].map { home.appendingPathComponent($0, isDirectory: true) }
    }

    static func packageField(_ root: URL, _ key: String) -> String? {
        guard let data = try? Data(contentsOf: root.appendingPathComponent("package.json")),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
        return object[key] as? String
    }

    /// "v24.11.1" > "v22.19.0" > "lts" (names without numbers sort last).
    static func newer(_ a: String, _ b: String) -> Bool {
        let x = numbers(a), y = numbers(b)
        for (left, right) in zip(x, y) where left != right { return left > right }
        return x.count != y.count ? x.count > y.count : a > b
    }
    private static func numbers(_ value: String) -> [Int] { value.split(whereSeparator: { !$0.isNumber }).compactMap { Int($0) } }
}
