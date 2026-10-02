import Foundation

/// Remaining budget for one period, from the tightest "all models" window.
public struct StudioQuotaSummary: Equatable, Sendable {
    public let period: String
    public let limit: Int64
    public let remaining: Int64
    public let endsAt: Date
    public var remainingRatio: Double { limit > 0 ? min(1, max(0, Double(remaining) / Double(limit))) : 0 }

    /// Day first, then month. Per-model windows and unknown counters are ignored.
    public static func from(_ quota: StudioQuota?) -> [StudioQuotaSummary] {
        guard let quota, quota.policy_allowed else { return [] }
        return ["day", "month"].compactMap { period in
            quota.windows.filter { $0.model_id == nil && $0.period == period && $0.tokens > 0 }
                .compactMap { w -> StudioQuotaSummary? in
                    guard let left = Int64(w.remaining_tokens.value) else { return nil }
                    return StudioQuotaSummary(period: period, limit: w.tokens, remaining: max(0, left), endsAt: w.ends_at)
                }
                .min { $0.remainingRatio < $1.remainingRatio }
        }
    }
}

/// One employee-facing state combining connection, key, quota and sync.
/// Priority follows the documented lifecycle: blockers before warnings.
public struct StudioEmployeeStatus: Equatable, Sendable {
    public enum Tone: Sendable { case ok, warning, danger, neutral }
    public enum Action: Sendable { case connect, allowKeychain, refresh, replaceKey, contactAdmin, showTools }
    public let title: String
    public let detail: String?
    public let tone: Tone
    public let action: Action?

    public static let expiringDays = 7
    public static let nearLimit = 0.2

    public static func evaluate(hasProfile: Bool, state: StudioConnectionStore.State, error: StudioError?, key: StudioKeyInfo?,
                                quota: [StudioQuotaSummary], failedTools: Int, now: Date = Date()) -> StudioEmployeeStatus {
        let date = { (d: Date) in d.formatted(.dateTime.day(.twoDigits).month(.twoDigits)) }
        let time = { (d: Date) in d.formatted(date: .omitted, time: .shortened) + " " + date(d) }
        let periodName = { (p: String) in p == "day" ? "hôm nay" : "tháng này" }
        guard hasProfile else { return .init(title: "Chưa kết nối", detail: "Nhập địa chỉ Studio và key được cấp.", tone: .neutral, action: .connect) }
        if error == .keychainApprovalRequired { return .init(title: "Cần cho phép Keychain", detail: "macOS cần xác nhận để đọc key.", tone: .warning, action: .allowKeychain) }
        if let key, key.expiresAt <= now, error == .invalidKey || error == nil {
            return .init(title: "Key đã hết hạn", detail: "Hết hạn ngày \(date(key.expiresAt)). Báo quản trị viên gia hạn.", tone: .danger, action: .contactAdmin)
        }
        if [.invalidKey, .permissionDenied, .identityChanged].contains(error) {
            return .init(title: "Key bị thu hồi hoặc không hợp lệ", detail: "Nhận key mới từ quản trị viên rồi thay key.", tone: .danger, action: .replaceKey)
        }
        if state == .stale || [.offline, .serverUnavailable, .upstreamUnavailable].contains(error) {
            return .init(title: "Mất kết nối", detail: "Đang hiện dữ liệu cũ.", tone: .neutral, action: .refresh)
        }
        if state == .checking { return .init(title: "Đang kiểm tra…", detail: nil, tone: .neutral, action: nil) }
        if state == .failed { return .init(title: "Chưa thể xác minh", detail: error?.localizedDescription, tone: .danger, action: .refresh) }
        if let empty = quota.first(where: { $0.remaining == 0 }) {
            return .init(title: "Hết hạn mức \(periodName(empty.period))", detail: "Mở lại lúc \(time(empty.endsAt)).", tone: .danger, action: nil)
        }
        if let key, key.daysLeft(now: now) <= expiringDays {
            return .init(title: "Key sắp hết hạn", detail: "Còn \(max(0, key.daysLeft(now: now))) ngày (\(date(key.expiresAt))). Báo quản trị viên gia hạn.", tone: .warning, action: .contactAdmin)
        }
        if let low = quota.first(where: { $0.remainingRatio <= nearLimit }) {
            return .init(title: "Gần hết hạn mức \(periodName(low.period))", detail: "Còn \(Int((low.remainingRatio * 100).rounded()))%.", tone: .warning, action: nil)
        }
        if failedTools > 0 { return .init(title: "\(failedTools) công cụ cần xử lý", detail: "Xem tab Công cụ.", tone: .warning, action: .showTools) }
        if state == .saved { return .init(title: "Đã lưu kết nối", detail: "Chưa kiểm tra lại.", tone: .neutral, action: .refresh) }
        let day = quota.first { $0.period == "day" }
        return .init(title: "Sẵn sàng", detail: day.map { "Còn \(Int(($0.remainingRatio * 100).rounded()))% hạn mức hôm nay" }, tone: .ok, action: nil)
    }
}

/// Models the key is granted (manifest) but Studio does not serve right now
/// (/v1/models): usually the team's AI account is paused or not ready.
public enum StudioModelAvailability {
    public static func unavailable(granted: [StudioModel], serving: [StudioModel]) -> [StudioModel] {
        let ids = Set(serving.map(\.id))
        return granted.filter { !ids.contains($0.id) }
    }
}
