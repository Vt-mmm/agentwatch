import Foundation

public struct ReportAccountMapping: Codable, Sendable, Equatable, Identifiable {
    public let id: String
    public let organizationID: String
    public let provider: String
    public let source: String
    public let sourceAccountKey: String?
    public let captureKey: String
    public let canonicalAccountKey: String
    public let confirmedBy: String
    public let confirmedAt: Date
    public let validFrom: Date
    public let validUntil: Date
    public init(organizationID: String, provider: String, source: String, sourceAccountKey: String?, captureKey: String,
                accountLabel: String, confirmedBy: String, validFrom: Date, validUntil: Date, now: Date = Date()) throws {
        guard !organizationID.isEmpty, !provider.isEmpty, !source.isEmpty, !captureKey.isEmpty,
              !accountLabel.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              !confirmedBy.isEmpty, validUntil > validFrom else { throw GoogleServiceError.invalidConfiguration }
        id = UUID().uuidString; self.organizationID = organizationID; self.provider = provider; self.source = source
        self.sourceAccountKey = sourceAccountKey; self.captureKey = captureKey
        canonicalAccountKey = ReportEncoding.digest(Data("\(organizationID)|\(provider)|\(accountLabel)".utf8))
        self.confirmedBy = confirmedBy; confirmedAt = now; self.validFrom = validFrom; self.validUntil = validUntil
    }
    func matches(_ snapshot: QuotaSnapshot) -> Bool {
        provider == snapshot.provider && source == snapshot.source && sourceAccountKey == snapshot.accountKey && captureKey == snapshot.captureKey
            && validFrom <= snapshot.capturedAt && snapshot.capturedAt < validUntil
    }
}

public struct ReportAccountMappingStore: Sendable {
    public let files: ReportFileStore
    public init(root: URL) { files = ReportFileStore(root: root) }
    public static var local: Self { Self(root: ReportSnapshotStore.local.files.root.appendingPathComponent("account-mappings")) }
    public func all() throws -> [ReportAccountMapping] { try files.transaction { try readUnlocked() } }
    public func save(_ mapping: ReportAccountMapping) throws {
        try files.transaction {
            let rows = try readUnlocked()
            guard !rows.contains(where: {
                $0.organizationID == mapping.organizationID && $0.provider == mapping.provider && $0.source == mapping.source
                    && $0.sourceAccountKey == mapping.sourceAccountKey && $0.captureKey == mapping.captureKey
                    && max($0.validFrom, mapping.validFrom) < min($0.validUntil, mapping.validUntil)
            }) else { throw ReportValidationError.invalid("Ánh xạ đã có trong khoảng thời gian này; không ghi đè lịch sử tài khoản.") }
            guard UUID(uuidString: mapping.id) != nil else { throw GoogleServiceError.invalidConfiguration }
            try files.write(ReportEncoding.encode(mapping), to: files.root.appendingPathComponent(mapping.id + ".json"))
        }
    }
    private func readUnlocked() throws -> [ReportAccountMapping] {
        try FileManager.default.contentsOfDirectory(at: files.root, includingPropertiesForKeys: nil)
            .filter { $0.pathExtension == "json" }.map { try ReportEncoding.decode(ReportAccountMapping.self, from: Data(contentsOf: $0)) }
    }
}

public enum ReportQuotaGrouping {
    /// Never sums percentages. A mapping only joins explicitly reviewed account
    /// captures during its bounded validity interval, not employee token usage.
    public static func latest(_ snapshots: [QuotaSnapshot], organizationID: String, mappings: [ReportAccountMapping]) -> [QuotaSnapshot] {
        let mapped = snapshots.map { sample -> QuotaSnapshot in
            let matches = mappings.filter { $0.organizationID == organizationID && $0.matches(sample) }
            guard matches.count == 1, let mapping = matches.first else { return sample }
            return QuotaSnapshot(provider: sample.provider, source: sample.source, sourceVersion: sample.sourceVersion,
                accountKey: mapping.canonicalAccountKey, captureKey: sample.captureKey, capturedAt: sample.capturedAt,
                availability: sample.availability, windows: sample.windows,
                warnings: sample.warnings + ["Account mapping \(mapping.id), confirmed by \(mapping.confirmedBy); not employee usage attribution."])
        }
        var seen: Set<String> = []
        return mapped.sorted {
            if $0.capturedAt != $1.capturedAt { return $0.capturedAt > $1.capturedAt }; return $0.id < $1.id
        }.compactMap { sample in
            let account = sample.accountKey ?? "unmapped|\(sample.source)|\(sample.captureKey)"
            let windows = sample.windows.filter { seen.insert("\(sample.provider)|\(account)|\($0.id)").inserted }
            if sample.windows.isEmpty {
                guard seen.insert("\(sample.provider)|\(account)|unavailable").inserted else { return nil }
            } else if windows.isEmpty { return nil }
            return QuotaSnapshot(provider: sample.provider, source: sample.source, sourceVersion: sample.sourceVersion,
                accountKey: sample.accountKey, captureKey: sample.captureKey + "|" + String(sample.capturedAt.timeIntervalSince1970), capturedAt: sample.capturedAt,
                availability: sample.availability, windows: windows, warnings: sample.warnings)
        }
    }
}
