import Foundation

public struct ReportRetentionCandidate: Codable, Sendable, Equatable, Identifiable {
    public enum Action: String, Codable, Sendable { case deleteFile, redactMailPreview }
    public let relativePath: String
    public let hash: String
    public let bytes: Int
    public let action: Action
    public var id: String { relativePath }
}
public struct ReportRetentionPlan: Codable, Sendable, Equatable {
    public let createdAt: Date
    public let retentionDays: Int
    public let candidates: [ReportRetentionCandidate]
    public var digest: String { ReportEncoding.digest((try? ReportEncoding.encode(self)) ?? Data()) }
}
public struct ReportRetentionService: Sendable {
    public let root: URL
    public init(root: URL = ReportSnapshotStore.local.files.root) { self.root = root }
    public func preview(retentionDays: Int, now: Date = Date()) throws -> ReportRetentionPlan {
        guard (7...3650).contains(retentionDays) else { throw GoogleServiceError.invalidConfiguration }
        let cutoff = now.addingTimeInterval(-Double(retentionDays) * 86_400)
        let snapshots = try ReportSnapshotStore(root: root).history()
        let gmail = try GmailOutboxStore(root: root.appendingPathComponent("gmail-outbox")).all()
        let drive = try DriveUploadStore(root: root.appendingPathComponent("drive-outbox")).all()
        let schedules = try ReportDeliveryScheduleStore(root: root.appendingPathComponent("delivery-schedules")).all()
        let scheduledJobs = Set(schedules.filter { [.queued, .running, .needsReview].contains($0.state) }.map(\.jobID))
        var protected: Set<String> = [], paths: [String] = [], previewPaths: Set<String> = []
        for job in gmail {
            if ![.accepted, .manuallyConfirmed].contains(job.state) || scheduledJobs.contains(job.id) {
                protected.insert("\(job.reportID)-r\(job.revision)")
            } else if job.createdAt < cutoff {
                paths += ["gmail-outbox/\(job.id).eml", "gmail-outbox/\(job.id).pdf"]
                if job.previewText != "Nội dung đã dọn theo thời hạn lưu; receipt được giữ lại." {
                    let metadataPath = "gmail-outbox/\(job.id).json"; paths.append(metadataPath); previewPaths.insert(metadataPath)
                }
            }
        }
        for job in drive {
            if job.state != .uploaded || scheduledJobs.contains(job.id) { protected.insert("\(job.reportID)-r\(job.revision)") }
            else if job.createdAt < cutoff { paths.append("drive-outbox/\(job.id).pdf") }
        }
        paths += snapshots.filter { $0.generatedAt < cutoff && !protected.contains($0.id) }.map { $0.id + ".json" }
        let candidates = try paths.sorted().compactMap { path -> ReportRetentionCandidate? in
            let url = root.appendingPathComponent(path)
            guard FileManager.default.fileExists(atPath: url.path) else { return nil }
            let values = try url.resourceValues(forKeys: [.isSymbolicLinkKey, .isRegularFileKey])
            guard values.isSymbolicLink != true, values.isRegularFile == true else { throw GoogleServiceError.invalidConfiguration }
            let bytes = try Data(contentsOf: url)
            return ReportRetentionCandidate(relativePath: path, hash: ReportEncoding.digest(bytes), bytes: bytes.count,
                                            action: previewPaths.contains(path) ? .redactMailPreview : .deleteFile)
        }
        return ReportRetentionPlan(createdAt: now, retentionDays: retentionDays, candidates: candidates)
    }
    public func execute(_ plan: ReportRetentionPlan, expectedDigest: String, now: Date = Date()) throws -> Int {
        guard plan.digest == expectedDigest, now >= plan.createdAt, now.timeIntervalSince(plan.createdAt) <= 300 else { throw GoogleServiceError.permissionDenied }
        // Recompute eligibility from current outboxes. Only delete exact files
        // present in the reviewed plan, never newly eligible files.
        let fresh = try preview(retentionDays: plan.retentionDays, now: now)
        let allowed = Dictionary(uniqueKeysWithValues: fresh.candidates.map { ($0.relativePath, $0) })
        guard plan.candidates.allSatisfy({ allowed[$0.relativePath] == $0 }) else { throw GoogleServiceError.conflict }
        for item in plan.candidates {
            let url = root.appendingPathComponent(item.relativePath)
            let bytes = try Data(contentsOf: url)
            guard ReportEncoding.digest(bytes) == item.hash else { throw GoogleServiceError.conflict }
            switch item.action {
            case .deleteFile: try FileManager.default.removeItem(at: url)
            case .redactMailPreview:
                try GmailOutboxStore(root: root.appendingPathComponent("gmail-outbox")).purgeCompletedPreview(url.deletingPathExtension().lastPathComponent, expectedFileHash: item.hash)
            }
        }
        return plan.candidates.count
    }
}
