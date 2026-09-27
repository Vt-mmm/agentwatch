import Foundation

public enum StudioLogIssue: String, Sendable, Equatable, CaseIterable {
    case invalidProfile, unsafePath, unreadable, limitReached, changedDuringRead, cancelled
    public var label: String {
        switch self {
        case .invalidProfile: "Có profile không hợp lệ; đã bỏ qua."
        case .unsafePath: "Có đường dẫn chuyển hướng; đã bỏ qua."
        case .unreadable: "Có file không đọc được hoặc chưa có dữ liệu phiên hợp lệ."
        case .limitReached: "Đã tới giới hạn lượt đọc; danh sách và số liệu chưa đầy đủ."
        case .changedDuringRead: "Log đang thay đổi trong lúc đọc; cần cập nhật lại."
        case .cancelled: "Lượt đọc đã hủy; số liệu chưa đầy đủ."
        }
    }
}
public struct StudioRegisteredLogs: Sendable, Equatable {
    public let provider: StudioCLIProvider
    public let profile: StudioCLIProfile?
    public let roots: [URL]
    public let issues: [StudioLogIssue]
}

/// Read the launcher's existing manifest, not terminal environment or a second
/// registration database. Only the selected origin/org/employee is discoverable.
public enum StudioLogRegistry {
    public static func read(connection: StudioProfile, directory: URL = StudioCLIProfiles.directory) -> [StudioRegisteredLogs] {
        StudioCLIProvider.allCases.map { provider in
            let root = directory.appendingPathComponent(connection.id, isDirectory: true).appendingPathComponent(provider.rawValue, isDirectory: true)
            let manifest = root.appendingPathComponent("profile.json")
            do {
                try requireUnredirected(manifest)
                guard FileManager.default.fileExists(atPath: manifest.path) else {
                    return StudioRegisteredLogs(provider: provider, profile: nil, roots: [], issues: [])
                }
                let values = try manifest.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey])
                guard values.isRegularFile == true, let size = values.fileSize, size <= 16_384 else { throw StudioCLIError.changedProfile }
                let profile = try JSONDecoder().decode(StudioCLIProfile.self, from: Data(contentsOf: manifest))
                guard profile.version == 1, profile.connection == connection, profile.provider == provider,
                      profile.root.isFileURL, profile.root.path == root.path else { throw StudioCLIError.changedProfile }
                let roots = provider == .claude ? [profile.logRoot] : [profile.logRoot, profile.config.appendingPathComponent("archived_sessions")]
                for root in roots { try requireUnredirected(root) }
                return StudioRegisteredLogs(provider: provider, profile: profile, roots: roots, issues: [])
            } catch {
                return StudioRegisteredLogs(provider: provider, profile: nil, roots: [], issues: [error as? StudioCLIError == .unsafePath ? .unsafePath : .invalidProfile])
            }
        }
    }
    static func requireUnredirected(_ path: URL) throws {
        guard path.isFileURL, !path.pathComponents.contains(".."), !path.pathComponents.contains(".") else { throw StudioCLIError.unsafePath }
        var component = path
        while component.path != "/" {
            if (try? component.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink) == true { throw StudioCLIError.unsafePath }
            component.deleteLastPathComponent()
        }
    }
}

public struct StudioLocalSession: Identifiable, Equatable, Sendable {
    public let profileID: String
    public let provider: StudioCLIProvider
    public let summary: SessionSummary
    public let sourcePartial: Bool
    public init(profileID: String, provider: StudioCLIProvider, summary: SessionSummary, sourcePartial: Bool = false) {
        self.profileID = profileID; self.provider = provider; self.summary = summary; self.sourcePartial = sourcePartial
    }
    public var id: String { profileID + "|" + provider.rawValue + "|" + summary.id }
    public var sessionID: String { summary.id }
    public var knownTokens: Int? {
        guard let entries = summary.usageEntries, entries.contains(where: { $0.tokens.isValid }) else { return nil }
        return UsageLedger(entries: entries).normalizedTokens.total
    }
    public var partial: Bool {
        sourcePartial || knownTokens == nil || summary.usageScope != .exactRange || UsageLedger(entries: summary.usageEntries ?? []).hasPartialUsage
    }
}
public struct StudioLocalLogSnapshot: Equatable, Sendable {
    public let connection: StudioProfile
    public let from, to, observedAt: Date
    public let registrations: [StudioRegisteredLogs]
    public let sessions: [StudioLocalSession]
    public let filesRead: Int
    public let issues: [StudioLogIssue]
    public var partial: Bool { !issues.isEmpty || sessions.contains(where: \.partial) }
}
public protocol StudioLocalLogReading: Sendable {
    func read(connection: StudioProfile, range: Range<Date>) async -> StudioLocalLogSnapshot
}
public struct StudioLocalLogReader: StudioLocalLogReading {
    public let directory: URL
    public init(directory: URL = StudioCLIProfiles.directory) { self.directory = directory }
    public func read(connection: StudioProfile, range: Range<Date>) async -> StudioLocalLogSnapshot {
        let task = Task.detached(priority: .utility) { Self.scan(connection: connection, range: range, directory: directory) }
        return await withTaskCancellationHandler { await task.value } onCancel: { task.cancel() }
    }
    // Bound scans of untrusted/growing local logs. A truncated scan is explicitly
    // partial, never a complete zero. Tests can lower limits to verify this gate.
    static func scan(connection: StudioProfile, range: Range<Date>, directory: URL,
                     maxFiles: Int = 1000, maxBytes: Int = 256 * 1024 * 1024) -> StudioLocalLogSnapshot {
        let registrations = StudioLogRegistry.read(connection: connection, directory: directory)
        var issues = Set(registrations.flatMap(\.issues)), filesRead = 0, bytesRead = 0, visited = 0
        var sessions: [StudioLocalSession] = [], fileIdentities: Set<String> = []
        for registration in registrations where registration.profile != nil {
            var summaries: [SessionSummary] = []
            for root in registration.roots {
                guard FileManager.default.fileExists(atPath: root.path) else { continue }
                guard let enumerator = FileManager.default.enumerator(at: root, includingPropertiesForKeys: [.isSymbolicLinkKey, .isRegularFileKey, .isDirectoryKey, .fileSizeKey, .contentModificationDateKey], options: [.skipsHiddenFiles], errorHandler: { _, _ in issues.insert(.unreadable); return false }) else { issues.insert(.unreadable); continue }
                for case let file as URL in enumerator {
                    visited += 1
                    if Task.isCancelled { issues.insert(.cancelled); break }
                    if visited > 20_000 || filesRead >= maxFiles || bytesRead >= maxBytes { issues.insert(.limitReached); break }
                    do {
                        let before = try file.resourceValues(forKeys: [.isSymbolicLinkKey, .isRegularFileKey, .isDirectoryKey, .fileSizeKey, .contentModificationDateKey])
                        if before.isSymbolicLink == true { enumerator.skipDescendants(); issues.insert(.unsafePath); continue }
                        guard file.pathExtension == "jsonl", before.isRegularFile == true else { continue }
                        try StudioLogRegistry.requireUnredirected(file)
                        let attrs = try FileManager.default.attributesOfItem(atPath: file.path)
                        guard let device = attrs[.systemNumber] as? NSNumber, let inode = attrs[.systemFileNumber] as? NSNumber,
                              let size = before.fileSize, size >= 0 else { issues.insert(.unreadable); continue }
                        let fileID = registration.provider.rawValue + "|" + device.stringValue + "|" + inode.stringValue
                        guard fileIdentities.insert(fileID).inserted else { continue }
                        guard size <= 64 * 1024 * 1024, size <= maxBytes - bytesRead else { issues.insert(.limitReached); continue }
                        guard FileManager.default.isReadableFile(atPath: file.path) else { issues.insert(.unreadable); continue }
                        filesRead += 1; bytesRead += size
                        let result: (summary: SessionSummary?, partial: Bool)
                        if registration.provider == .claude {
                            result = claudeSummary(file: file, range: range, maxBytes: size)
                        } else { result = CodexJsonlParser.summarizeWithDiagnostics(file: file, range: range, maxBytes: size) }
                        var currentFile = file
                        currentFile.removeAllCachedResourceValues()
                        let after = try currentFile.resourceValues(forKeys: [.fileSizeKey, .contentModificationDateKey])
                        if before.fileSize != after.fileSize || before.contentModificationDate != after.contentModificationDate { issues.insert(.changedDuringRead) }
                        if let summary = result.summary { summaries.append(summary) }
                        else if result.partial { issues.insert(.unreadable) }
                        // A log with no events in the selected range is normally
                        // absent from the result; absence is not an inferred zero.
                    } catch { issues.insert(.unreadable) }
                }
            }
            let incomplete = Set(summaries.filter { $0.usageScope != .exactRange }.map(\.auditKey))
            sessions += SessionAccounting.canonical(summaries).map { StudioLocalSession(profileID: connection.id, provider: registration.provider, summary: $0, sourcePartial: incomplete.contains($0.auditKey)) }
        }
        return StudioLocalLogSnapshot(connection: connection, from: range.lowerBound, to: range.upperBound, observedAt: Date(), registrations: registrations,
                                      sessions: sessions.sorted { ($0.summary.lastTimestamp ?? .distantPast) > ($1.summary.lastTimestamp ?? .distantPast) },
                                      filesRead: filesRead, issues: StudioLogIssue.allCases.filter(issues.contains))
    }
    private static func claudeSummary(file: URL, range: Range<Date>, maxBytes: Int) -> (summary: SessionSummary?, partial: Bool) {
        let stats = JsonlParser.parseSession(at: file, range: range, eventLimit: 0, maxBytes: maxBytes)
        let partial = stats.usageLedger.hasPartialUsage
        guard let first = parseDate(stats.startedAt), let last = parseDate(stats.lastEventAt) else { return (nil, partial) }
        return (SessionSummary(id: stats.sessionId, projectDisplay: ProjectPath.displayPath(for: stats.projectSlug), source: .cli, model: stats.model, modelFamily: stats.modelFamily,
                              inputTokens: stats.inputTokens, outputTokens: stats.outputTokens, reasoningTokens: stats.reasoningTokens, cacheReadTokens: stats.cacheReadTokens, cacheWriteTokens: stats.cacheWriteTokens, cost: stats.cost,
                              firstTimestamp: first, lastTimestamp: last, promptCount: stats.promptCount, toolCallCount: stats.toolCalls, fileURL: file, agentCount: stats.agents.count,
                              costBasis: stats.costBasis, usageScope: partial ? .partialRange : .exactRange, dataWarnings: stats.usageLedger.warnings, usageEntries: stats.usageLedger.entries), partial)
    }
    private static func parseDate(_ value: String) -> Date? {
        let formatter = ISO8601DateFormatter(); formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = formatter.date(from: value) { return date }
        formatter.formatOptions = [.withInternetDateTime]; return formatter.date(from: value)
    }
}
