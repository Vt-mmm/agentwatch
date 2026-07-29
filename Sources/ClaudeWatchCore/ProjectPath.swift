// Claude Code stores transcripts under ~/.claude/projects/<slug>/<uuid>.jsonl
// where slug = cwd with '/' replaced by '-' (leading '-' kept).

import Foundation

public enum ProjectPath {
    public static let projectsDir: URL = {
        let home = FileManager.default.homeDirectoryForCurrentUser
        return home.appendingPathComponent(".claude/projects", isDirectory: true)
    }()

    /// Claude Code's slug rule: replace `/`, `.`, and `_` with `-`.
    /// "/Users/vtamm/Documents/Claude_management" → "-Users-vtamm-Documents-Claude-management"
    public static func slug(for cwd: URL) -> String {
        let path = cwd.standardizedFileURL.path
        var s = ""
        s.reserveCapacity(path.count)
        for ch in path {
            switch ch {
            case "/", ".", "_": s.append("-")
            default: s.append(ch)
            }
        }
        return s
    }

    /// Inverse is lossy (we don't know which '-' was originally '/', '.', or '_').
    /// Return a best-effort display path with leading slash preserved.
    public static func displayPath(for slug: String) -> String {
        if slug.hasPrefix("-") {
            return "/" + slug.dropFirst().replacingOccurrences(of: "-", with: "/")
        }
        return slug.replacingOccurrences(of: "-", with: "/")
    }

    /// All JSONL files for a project slug (unsorted).
    public static func sessionFiles(slug: String) -> [URL] {
        let dir = projectsDir.appendingPathComponent(slug, isDirectory: true)
        guard let entries = try? FileManager.default.contentsOfDirectory(
            at: dir, includingPropertiesForKeys: [.contentModificationDateKey],
            options: [.skipsHiddenFiles]
        ) else { return [] }
        return entries.filter { $0.pathExtension == "jsonl" }
    }

    /// Most recently modified session for this folder; walks up parents
    /// so subdirectories of a tracked project still resolve.
    public static func latestSession(for cwd: URL) -> URL? {
        var current: URL? = cwd.standardizedFileURL
        while let dir = current {
            let candidates = sessionFiles(slug: slug(for: dir))
            if let newest = candidates.max(by: { lhs, rhs in
                mtime(of: lhs) < mtime(of: rhs)
            }) {
                return newest
            }
            let parent = dir.deletingLastPathComponent()
            if parent.path == dir.path { return nil }   // hit root
            current = parent
        }
        return nil
    }

    public static func mtime(of url: URL) -> Date {
        let values = try? url.resourceValues(forKeys: [.contentModificationDateKey])
        return values?.contentModificationDate ?? .distantPast
    }

    /// Scan every `<projects>/<slug>/*.jsonl` and return the JSONL whose mtime
    /// is the most recent. Used by snapshot mode to pick the latest session.
    public static func mostRecentSessionAcrossAllProjects() -> URL? {
        guard let projects = try? FileManager.default.contentsOfDirectory(
            at: projectsDir,
            includingPropertiesForKeys: [.contentModificationDateKey],
            options: [.skipsHiddenFiles]
        ) else { return nil }

        var newest: (URL, Date)?
        for project in projects where project.hasDirectoryPath {
            guard let files = try? FileManager.default.contentsOfDirectory(
                at: project,
                includingPropertiesForKeys: [.contentModificationDateKey],
                options: [.skipsHiddenFiles]
            ) else { continue }
            for file in files where file.pathExtension == "jsonl" {
                let m = mtime(of: file)
                if newest == nil || m > newest!.1 {
                    newest = (file, m)
                }
            }
        }
        return newest?.0
    }

    /// The folder (decoded from slug) of the most-recent session, if any.
    /// This is the "latest snapshot" entrypoint for the UI.
    public static func mostRecentActiveProjectFolder() -> URL? {
        guard let session = mostRecentSessionAcrossAllProjects() else { return nil }
        let slug = session.deletingLastPathComponent().lastPathComponent
        return URL(fileURLWithPath: displayPath(for: slug))
    }
}
