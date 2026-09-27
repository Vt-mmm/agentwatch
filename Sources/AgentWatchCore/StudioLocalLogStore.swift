import Foundation
import Observation

@MainActor @Observable public final class StudioLocalLogStore {
    public private(set) var snapshot: StudioLocalLogSnapshot?
    public private(set) var loading = false
    @ObservationIgnored private let reader: any StudioLocalLogReading
    @ObservationIgnored private var generation: UInt64 = 0
    public init(reader: any StudioLocalLogReading = StudioLocalLogReader()) { self.reader = reader }
    public func clear() { generation &+= 1; snapshot = nil; loading = false }
    public func refresh(connection: StudioProfile, range: Range<Date>) async {
        generation &+= 1; let token = generation
        snapshot = nil; loading = true
        let value = await reader.read(connection: connection, range: range)
        guard token == generation else { return }
        loading = false
        guard !Task.isCancelled else { return }
        guard value.connection == connection, value.from == range.lowerBound, value.to == range.upperBound else { return }
        snapshot = value
    }
}
