import Foundation

public enum AgentWatchIdentity {
    public static let productName = "AgentWatch"
    public static let macAppName = "AgentWatchMac"
    public static let supportDirectoryName = "AgentWatch"

    public static let legacySupportDirectoryNames = [
        "Agent Watch",
        "ClaudeWatch",
        "ClaudeWatchMac"
    ]

    public static func applicationSupportDirectory(
        fileManager: FileManager = .default,
        createIfNeeded: Bool = true
    ) -> URL {
        let base = fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? fileManager.homeDirectoryForCurrentUser
                .appendingPathComponent("Library/Application Support", isDirectory: true)
        let current = base.appendingPathComponent(supportDirectoryName, isDirectory: true)

        guard createIfNeeded else { return current }

        try? fileManager.createDirectory(at: current, withIntermediateDirectories: true)
        migrateLegacySupportDirectories(from: base, to: current, fileManager: fileManager)
        return current
    }

    private static func migrateLegacySupportDirectories(
        from base: URL,
        to current: URL,
        fileManager: FileManager
    ) {
        for name in legacySupportDirectoryNames {
            let legacy = base.appendingPathComponent(name, isDirectory: true)
            guard fileManager.fileExists(atPath: legacy.path),
                  let items = try? fileManager.contentsOfDirectory(
                    at: legacy,
                    includingPropertiesForKeys: nil
                  ) else {
                continue
            }

            for item in items {
                let destination = current.appendingPathComponent(item.lastPathComponent)
                guard !fileManager.fileExists(atPath: destination.path) else { continue }
                try? fileManager.moveItem(at: item, to: destination)
            }

            if let remaining = try? fileManager.contentsOfDirectory(
                at: legacy,
                includingPropertiesForKeys: nil
            ), remaining.isEmpty {
                try? fileManager.removeItem(at: legacy)
            }
        }
    }
}

public enum AgentWatchLocale {
    /// ISO 639-1 language code for Vietnamese. Keep lowercase by convention.
    public static let languageCode = "vi"

    /// ISO 3166-1 alpha-2 region code for Viet Nam. Keep uppercase by convention.
    public static let regionCode = "VN"

    public static let identifier = "\(languageCode)_\(regionCode)"
    public static let htmlLanguageTag = languageCode
    public static let timeZoneIdentifier = "Asia/Ho_Chi_Minh"
    public static let timeZoneLabel = "GMT+7"

    public static var locale: Locale {
        Locale(identifier: identifier)
    }

    public static var timeZone: TimeZone {
        TimeZone(identifier: timeZoneIdentifier)
            ?? TimeZone(secondsFromGMT: 7 * 60 * 60)
            ?? .current
    }
}
