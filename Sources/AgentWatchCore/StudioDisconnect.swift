import Foundation

public enum StudioDisconnectChoice: Sendable { case keepCLI, closeCLI }
public struct StudioDisconnectResult: Sendable {
    public let choice: StudioDisconnectChoice
    public let closed, remaining, unverified: Int
    public let incomplete: Bool
    public var message: String {
        if choice == .keepCLI {
            return "Đã ngắt kết nối trên Mac và giữ các phiên CLI. Phiên đang chạy vẫn có key trong bộ nhớ; muốn thu hồi quyền ngay, hãy thu hồi key trên Studio."
        }
        let detail = "Đã ngắt kết nối trên Mac. CLI đã kết thúc: \(closed); còn chạy: \(remaining); chưa xác minh: \(unverified)."
        return detail + (incomplete ? " Danh sách phiên chưa đầy đủ; kiểm tra các cửa sổ Terminal." : "")
    }
}

public enum StudioDisconnect {
    /// The captured identity prevents an old confirmation from disconnecting a
    /// newly selected account. Re-snapshot under the same lock used at exec.
    /// No lock is held while waiting for a native process to terminate.
    @MainActor public static func perform(store: StudioConnectionStore, expected: StudioProfile,
                                         choice: StudioDisconnectChoice, registry: StudioProcessRegistry = StudioProcessRegistry()) async throws -> StudioDisconnectResult {
        let inventory = try registry.withLaunchLock(connection: expected) {
            guard store.profile == expected else { throw StudioError.identityChanged }
            let inventory = registry.snapshot(connection: expected)
            store.disconnect()
            guard store.profile == nil, store.state == .disconnected else { throw StudioError.storage }
            return inventory
        }
        guard choice == .closeCLI else {
            return StudioDisconnectResult(choice: choice, closed: 0, remaining: inventory.entries.filter { $0.state == .running }.count,
                                          unverified: inventory.entries.filter { $0.state == .unverified }.count, incomplete: inventory.incomplete)
        }
        var closed = 0, remaining = 0, unverified = 0
        for entry in inventory.entries where entry.state != .finished {
            do {
                switch try await registry.stop(entry.process) {
                case .finished: closed += 1
                case .running: remaining += 1
                case .unverified: unverified += 1
                }
            } catch { unverified += 1 }
        }
        return StudioDisconnectResult(choice: choice, closed: closed, remaining: remaining, unverified: unverified, incomplete: inventory.incomplete)
    }
}
