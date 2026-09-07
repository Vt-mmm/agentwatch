import Foundation

public enum DesktopInteractionState: String, Codable, Sendable {
    case recentInput, idle, unknown
    public var label: String {
        switch self {
        case .recentInput: "Có tương tác gần đây"
        case .idle: "Không thao tác trên 60 giây"
        case .unknown: "Chưa phân loại tương tác"
        }
    }
    public static func observed(idleSeconds: Double) -> Self {
        guard idleSeconds.isFinite, idleSeconds >= 0 else { return .unknown }
        return idleSeconds >= 60 ? .idle : .recentInput
    }
}

/// Foreground observation only: no window titles, URLs, document names or content.
public struct DesktopAppInterval: Codable, Sendable, Equatable, Identifiable {
    public let id: String
    public let employeeID: String
    public let bundleID: String
    public let name: String
    public let start: Date
    public let end: Date
    public var interaction: DesktopInteractionState?
    public init(id: String = UUID().uuidString, employeeID: String, bundleID: String, name: String, start: Date, end: Date, interaction: DesktopInteractionState? = nil) {
        self.id = id; self.employeeID = employeeID; self.bundleID = bundleID; self.name = name; self.start = start; self.end = end
        self.interaction = interaction
    }
}
public struct DesktopAppSummary: Codable, Sendable, Equatable, Identifiable {
    public let id: String
    public let name: String
    public let seconds: Double
}
public struct DesktopActivityReport: Codable, Sendable, Equatable {
    public let collectionStartedAt: Date?
    public let observedSeconds: Double
    public let apps: [DesktopAppSummary]
    public var timeline: [DesktopActivitySpan]?
}
public struct DesktopActivitySpan: Codable, Sendable, Equatable {
    public let name: String
    public let start: Date
    public var end: Date
    public let interaction: DesktopInteractionState
}
public struct DesktopAppActivityStore: Sendable {
    public let files: ReportFileStore
    public init(root: URL) { files = ReportFileStore(root: root) }
    public static var local: Self {
        Self(root: ReportSnapshotStore.local.files.root.appendingPathComponent("desktop-activity"))
    }
    public func append(_ interval: DesktopAppInterval) throws {
        guard !interval.employeeID.isEmpty, interval.end > interval.start,
              interval.end.timeIntervalSince(interval.start) <= 60 else { return }
        try files.transaction {
            // One shard per UTC day; reporting clips intervals in the employee's timezone.
            let day = DailyReportRenderer.dateLabel(interval.start, zone: "UTC", format: "yyyy-MM-dd")
            let url = files.root.appendingPathComponent(day + ".jsonl")
            if !FileManager.default.fileExists(atPath: url.path) {
                _ = FileManager.default.createFile(atPath: url.path, contents: nil, attributes: [.posixPermissions: 0o600])
            }
            let handle = try FileHandle(forWritingTo: url); defer { try? handle.close() }
            try handle.seekToEnd()
            var bytes = try ReportEncoding.encode(interval); bytes.append(10); try handle.write(contentsOf: bytes)
            let marker = files.root.appendingPathComponent("started-" + ReportEncoding.digest(Data(interval.employeeID.utf8)) + ".json")
            if !FileManager.default.fileExists(atPath: marker.path) { try files.write(ReportEncoding.encode(interval.start), to: marker) }
        }
    }
    public func report(employeeID: String, period: DailyReportPeriod) throws -> DesktopActivityReport {
        try files.transaction {
            let marker = files.root.appendingPathComponent("started-" + ReportEncoding.digest(Data(employeeID.utf8)) + ".json")
            let started = FileManager.default.fileExists(atPath: marker.path) ? try ReportEncoding.decode(Date.self, from: Data(contentsOf: marker)) : nil
            var intervals: [DesktopAppInterval] = []
            let days = Set([period.start.addingTimeInterval(-60), period.start, period.end].map {
                DailyReportRenderer.dateLabel($0, zone: "UTC", format: "yyyy-MM-dd")
            })
            for day in days {
                let url = files.root.appendingPathComponent(day + ".jsonl")
                guard FileManager.default.fileExists(atPath: url.path) else { continue }
                var invalid = false
                JsonlLineReader.forEachLineData(at: url) { data in
                    if let interval = try? ReportEncoding.decode(DesktopAppInterval.self, from: data) { intervals.append(interval) }
                    else { invalid = true }
                }
                if invalid { throw ReportValidationError.invalid("Lịch sử ứng dụng có dòng lỗi; chưa thể tổng hợp đầy đủ.") }
            }
            return Self.summarize(intervals, employeeID: employeeID, period: period, started: started)
        }
    }
    public static func summarize(_ intervals: [DesktopAppInterval], employeeID: String, period: DailyReportPeriod, started: Date?) -> DesktopActivityReport {
        var seen = Set<String>(), totals: [String: Double] = [:], names: [String: String] = [:]
        var cursor = period.start
        var timeline: [DesktopActivitySpan] = []
        for row in intervals.filter({ $0.employeeID == employeeID }).sorted(by: { $0.start == $1.start ? $0.id < $1.id : $0.start < $1.start }) {
            guard seen.insert(row.id).inserted, row.end > row.start, row.end.timeIntervalSince(row.start) <= 60 else { continue }
            let start = max(row.start, cursor, period.start), end = min(row.end, period.end, period.cutoff)
            guard end > start else { continue }
            totals[row.bundleID, default: 0] += end.timeIntervalSince(start)
            names[row.bundleID] = ShareText.clean(row.name); cursor = end
            let state = row.interaction ?? .unknown
            if let last = timeline.last, last.name == names[row.bundleID], last.interaction == state,
               abs(last.end.timeIntervalSince(start)) < 0.001 {
                timeline[timeline.count - 1].end = end
            } else {
                timeline.append(DesktopActivitySpan(name: names[row.bundleID]!, start: start, end: end, interaction: state))
            }
        }
        let apps = totals.keys.sorted().map { DesktopAppSummary(id: $0, name: names[$0] ?? $0, seconds: totals[$0]!) }
        return DesktopActivityReport(collectionStartedAt: started, observedSeconds: apps.reduce(0) { $0 + $1.seconds }, apps: apps, timeline: timeline)
    }
}
