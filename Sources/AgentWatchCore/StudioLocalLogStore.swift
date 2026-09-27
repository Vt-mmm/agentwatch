import Foundation
import Observation

@MainActor @Observable public final class StudioLocalLogStore {
    public private(set) var snapshot: StudioLocalLogSnapshot?
    public private(set) var loading = false
    public private(set) var comparing = false
    public private(set) var comparisons: [String: StudioSessionComparison] = [:]
    @ObservationIgnored private let reader: any StudioLocalLogReading
    @ObservationIgnored private var generation: UInt64 = 0
    public init(reader: any StudioLocalLogReading = StudioLocalLogReader()) { self.reader = reader }
    public func clear() { generation &+= 1; snapshot = nil; loading = false; comparing = false; comparisons = [:] }
    public func compare(using studio: StudioConnectionStore) async {
        guard let snapshot, studio.profile == snapshot.connection else { return }
        generation &+= 1
        let token = generation, revision = studio.sessionReportsRevision
        comparisons = [:]; comparing = true
        var results: [String: StudioSessionComparison] = [:]
        var cancelled = false
        for session in snapshot.sessions.prefix(20) {
            do {
                results[session.id] = try await studio.compareSession(session, range: snapshot.from..<snapshot.to, coveragePartial: !snapshot.issues.isEmpty)
            } catch is CancellationError { cancelled = true; break }
            catch {
                // One failed connection should not cause twenty sequential timeouts.
                for row in snapshot.sessions.prefix(20) where results[row.id] == nil { results[row.id] = .unavailable() }
                break
            }
            if token != generation || Task.isCancelled { break }
        }
        guard token == generation else { return }
        comparing = false
        guard !cancelled, !Task.isCancelled, studio.sessionReportsRevision == revision, studio.state == .connected, studio.profile == snapshot.connection else { comparisons = [:]; return }
        comparisons = results
    }
    public func refresh(connection: StudioProfile, range: Range<Date>) async {
        generation &+= 1; let token = generation
        snapshot = nil; loading = true; comparing = false; comparisons = [:]
        let value = await reader.read(connection: connection, range: range)
        guard token == generation else { return }
        loading = false
        guard !Task.isCancelled else { return }
        guard value.connection == connection, value.from == range.lowerBound, value.to == range.upperBound else { return }
        snapshot = value
    }
}
