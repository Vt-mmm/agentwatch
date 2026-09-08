import Foundation

public enum SourceHealthState: String, Codable, Sendable {
    case available, empty, missing, unreadable, partial
    public var label: String {
        switch self {
        case .available: "Đã đọc được"
        case .empty: "Không có session trong mẫu đã đọc"
        case .missing: "Chưa tìm thấy nguồn"
        case .unreadable: "Không có quyền hoặc không đọc được"
        case .partial: "Dữ liệu một phần"
        }
    }
}

public struct InsightSourceHealth: Codable, Sendable, Identifiable {
    public let path: String
    public let state: SourceHealthState
    public let sessionCount: Int
    public let lastObservedEvent: Date?
    public let warnings: [String]
    public var id: String { path }
}

public struct InsightDataHealth: Codable, Sendable {
    public let checkedAt: Date
    public let sources: [InsightSourceHealth]
    public let unallocatedTokens: Int
    public let partialSessionCount: Int
    public let telemetryMalformedCount: Int
    public let telemetryUnsupportedCount: Int
    public let telemetryCoverage: InsightCoverage
    public let warnings: [String]

    public static func build(scan: CoachingScanResult, telemetry: ContextTelemetrySnapshot,
                             lifecycle: TaskLifecycleSnapshot, checkedAt: Date = Date()) -> Self {
        let sources = scan.sourceRoots.map { root in
            let sessions = scan.sessions.filter { session in
                guard let path = session.fileURL?.standardizedFileURL.path else { return false }
                let prefix = URL(fileURLWithPath: root.path).standardizedFileURL.path
                return path.hasPrefix(prefix + "/")
            }
            let prefix = URL(fileURLWithPath: root.path).standardizedFileURL.path + "/"
            let manifests = scan.sourceFiles.filter { URL(fileURLWithPath: $0.path).standardizedFileURL.path.hasPrefix(prefix) }
            var warnings = Array(Set(sessions.flatMap(\.dataWarnings))).sorted()
            let malformed = manifests.reduce(0) { $0 + $1.malformedRecordCount }
            if malformed > 0 { warnings.append("\(malformed) dòng JSON lỗi hoặc quá lớn trong kiểm kê nguồn.") }
            if manifests.contains(where: { !$0.readable }) { warnings.append("Có file không đọc được trong kiểm kê nguồn.") }
            if manifests.contains(where: \.changedDuringRead) { warnings.append("Có file thay đổi trong lúc kiểm kê; dữ liệu chưa ổn định.") }
            let hasPartial = sessions.contains { $0.usageScope == .partialRange } || !warnings.isEmpty
            let state: SourceHealthState = !root.exists ? .missing : !root.readable ? .unreadable
                : hasPartial ? .partial : sessions.isEmpty ? .empty : .available
            return InsightSourceHealth(path: root.path, state: state, sessionCount: sessions.count,
                lastObservedEvent: sessions.compactMap(\.lastTimestamp).max(), warnings: warnings)
        }
        var warnings = lifecycle.warnings + telemetry.warnings
        if scan.candidateFileCount > 0 && scan.sessions.isEmpty && scan.prompts.isEmpty {
            warnings.append("Đã thấy \(scan.candidateFileCount) file log nhưng chưa trích được session/prompt trong khoảng chọn. Có thể ngoài thời gian, chưa hỗ trợ hoặc không đọc được; không kết luận nguồn không có hoạt động.")
        }
        warnings.append("Schema chưa được hỗ trợ ngoài telemetry Pi không có bộ đếm đầy đủ; không diễn giải phần chưa biết thành 0 lỗi.")
        if scan.sourceFiles.isEmpty {
            warnings.append("Lượt đọc nhanh chưa kiểm kê đầy đủ từng file nguồn; số dòng lỗi/schema ngoài telemetry Pi chưa được xác nhận đầy đủ.")
        }
        return Self(checkedAt: checkedAt, sources: sources, unallocatedTokens: lifecycle.unallocatedTokens,
            partialSessionCount: scan.sessions.filter { $0.usageScope == .partialRange }.count,
            telemetryMalformedCount: telemetry.malformedRecords, telemetryUnsupportedCount: telemetry.unsupportedRecords,
            telemetryCoverage: telemetry.coverage, warnings: Array(Set(warnings)).sorted())
    }
}
