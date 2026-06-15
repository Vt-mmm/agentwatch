// MetricsCollector.swift
// Thu thập MetricKit payloads hàng ngày từ macOS và lưu vào disk để phân tích offline.
// SILENT / NO-UI — không có giao diện người dùng, chỉ ghi file nền.
// Dữ liệu lưu tại: ~/Library/Application Support/ClaudeWatch/metrics/
// Yêu cầu macOS 12+. Project target macOS 14 → không cần @available guard.

import Foundation
import MetricKit
import os.log

/// Subscriber nhận MetricKit payloads (metric + diagnostic) và persist vào disk.
/// Chỉ lưu tối đa 30 files gần nhất — tránh tăng trưởng disk không giới hạn.
@MainActor
final class MetricsCollector: NSObject, MXMetricManagerSubscriber {

    // MARK: - Singleton

    static let shared = MetricsCollector()

    // MARK: - Private state

    private let logger = Logger(subsystem: "com.claudewatch.mac", category: "metrics")

    /// Thư mục lưu payload: ~/Library/Application Support/ClaudeWatch/metrics/
    private let metricsDir: URL

    // MARK: - Init

    override init() {
        let support = FileManager.default.urls(
            for: .applicationSupportDirectory,
            in: .userDomainMask
        ).first!
        self.metricsDir = support.appendingPathComponent("ClaudeWatch/metrics", isDirectory: true)
        // Tạo thư mục nếu chưa có; bỏ qua lỗi nếu đã tồn tại.
        try? FileManager.default.createDirectory(
            at: metricsDir,
            withIntermediateDirectories: true
        )
        super.init()
    }

    // MARK: - Lifecycle

    /// Bắt đầu nhận payloads từ MXMetricManager. Gọi 1 lần trong app init.
    func start() {
        MXMetricManager.shared.add(self)
        logger.info("MetricsCollector: đã đăng ký MXMetricManager — payloads sẽ lưu tại \(self.metricsDir.path, privacy: .public)")
    }

    /// Hủy đăng ký. Gọi khi app terminate nếu cần cleanup tường minh.
    func stop() {
        MXMetricManager.shared.remove(self)
        logger.info("MetricsCollector: đã hủy đăng ký MXMetricManager")
    }

    // MARK: - MXMetricManagerSubscriber

    /// Nhận metric payloads hàng ngày (CPU, memory, launch time, animation hitches…).
    /// nonisolated vì MXMetricManagerSubscriber callback đến từ framework thread không biết về MainActor.
    /// jsonRepresentation() được gọi ngay tại đây (nonisolated) để chỉ gửi Data (Sendable) qua actor boundary.
    /// Điều này tránh lỗi Swift 6 "sending non-Sendable value across actor boundaries".
    nonisolated func didReceive(_ payloads: [MXMetricPayload]) {
        for payload in payloads {
            let data = payload.jsonRepresentation()
            Task { @MainActor in
                await persistData(data, suffix: "metric")
            }
        }
    }

    /// Nhận diagnostic payloads (crash reports, hang reports, disk write exceptions…).
    nonisolated func didReceive(_ payloads: [MXDiagnosticPayload]) {
        for payload in payloads {
            let data = payload.jsonRepresentation()
            Task { @MainActor in
                await persistData(data, suffix: "diagnostic")
            }
        }
    }

    // MARK: - Persistence

    /// Ghi Data đã serialize vào metricsDir.
    /// Tên file: {ISO8601-timestamp}-{suffix}.json, ví dụ: 2026-06-15T12-30-00Z-metric.json
    private func persistData(_ data: Data, suffix: String) async {
        // Tạo timestamp an toàn cho tên file (thay ":" thành "-").
        let timestamp = ISO8601DateFormatter()
            .string(from: Date())
            .replacingOccurrences(of: ":", with: "-")
        let filename = "\(timestamp)-\(suffix).json"
        let path = metricsDir.appendingPathComponent(filename)

        do {
            // .atomic đảm bảo ghi hoàn chỉnh — tránh file corrupt nếu app bị kill giữa chừng.
            try data.write(to: path, options: .atomic)
            logger.info("MetricsCollector: đã ghi \(suffix, privacy: .public) payload → \(filename, privacy: .public)")
            // Dọn dẹp files cũ ngay sau mỗi lần ghi.
            await pruneOldMetrics()
        } catch {
            logger.error("MetricsCollector: lỗi ghi \(suffix, privacy: .public) — \(error.localizedDescription, privacy: .public)")
        }
    }

    // MARK: - Pruning

    /// Giữ tối đa 30 files gần nhất — tránh tăng trưởng disk không giới hạn.
    /// Files được sắp xếp theo ngày tạo mới nhất trước; xóa phần thừa.
    private func pruneOldMetrics() async {
        guard let files = try? FileManager.default.contentsOfDirectory(
            at: metricsDir,
            includingPropertiesForKeys: [.creationDateKey]
        ) else { return }

        // Sắp xếp: mới nhất đứng đầu.
        let sorted = files.sorted { a, b in
            let aDate = (try? a.resourceValues(forKeys: [.creationDateKey]))?.creationDate ?? .distantPast
            let bDate = (try? b.resourceValues(forKeys: [.creationDateKey]))?.creationDate ?? .distantPast
            return aDate > bDate
        }

        // Chỉ giữ 30 files đầu; xóa phần còn lại.
        let maxFiles = 30
        if sorted.count > maxFiles {
            for old in sorted.dropFirst(maxFiles) {
                do {
                    try FileManager.default.removeItem(at: old)
                    logger.debug("MetricsCollector: đã xóa file cũ \(old.lastPathComponent, privacy: .public)")
                } catch {
                    logger.warning("MetricsCollector: không xóa được \(old.lastPathComponent, privacy: .public) — \(error.localizedDescription, privacy: .public)")
                }
            }
        }
    }
}
