// Pet mascot state — derive từ coaching/session data. Shared giữa SwiftUI
// app (top-bar mascot) và CLI (ASCII art). Pure logic, không UI dependency.

import Foundation

public enum PetState: String, Sendable, CaseIterable {
    case sleepy   // không có session active hoặc <5 prompt trong ngày
    case happy    // bình thường, burn rate thấp
    case excited  // avg ★ tăng so với kỳ trước (≥0.3)
    case worried  // có cost outlier vượt robust cohort baseline
    case dizzy    // có agent loop (≥10 Agent invocation/session)

    /// Caption ngắn cho tooltip hoặc CLI line.
    public var caption: String {
        switch self {
        case .sleepy:  return "Đang ngủ — chưa có hoạt động"
        case .happy:   return "Burn rate ổn định"
        case .excited: return "Chất lượng prompt tăng!"
        case .worried: return "Session bất thường về cost"
        case .dizzy:   return "Agent loop nguy hiểm — coi chừng tốn token"
        }
    }

    /// ASCII art 3 dòng cho CLI. Width ~9 chars để fit terminal hẹp.
    public var asciiArt: [String] {
        switch self {
        case .sleepy:
            return [" /\\_/\\  ",
                    "(  -.- )",
                    " > z z <"]
        case .happy:
            return [" /\\_/\\  ",
                    "( ^.^ )",
                    " > w < "]
        case .excited:
            return [" /\\_/\\  ",
                    "( *o* )",
                    " > ^ < "]
        case .worried:
            return [" /\\_/\\  ",
                    "( O.o )",
                    " > ~ < "]
        case .dizzy:
            return [" /\\_/\\  ",
                    "( @.@ )",
                    " > x < "]
        }
    }
}

/// Tổng hợp signal cho pet — caller truyền sẵn các chỉ số đã derive
/// (insights/outliers tính ở caller, pet logic chỉ pick state).
public struct PetSignals: Sendable {
    public let hasActivity: Bool         // có session trong khoảng đang xem
    public let outlierCount: Int         // số session vượt median/MAD baseline
    public let agentLoopCount: Int       // số session có ≥10 Agent
    public let avgStarsDelta: Double     // avg★ − previous avg★

    public init(hasActivity: Bool, outlierCount: Int,
                agentLoopCount: Int, avgStarsDelta: Double) {
        self.hasActivity = hasActivity
        self.outlierCount = outlierCount
        self.agentLoopCount = agentLoopCount
        self.avgStarsDelta = avgStarsDelta
    }
}

public enum PetMood {
    /// Priority: dizzy > worried > excited > sleepy > happy.
    /// Dizzy/worried là cảnh báo nên ưu tiên hiển thị; excited là feedback tích cực
    /// dành cho khi không có warning; sleepy là fallback khi vắng data.
    public static func resolve(_ s: PetSignals) -> PetState {
        if s.agentLoopCount > 0 { return .dizzy }
        if s.outlierCount > 0   { return .worried }
        if s.avgStarsDelta >= 0.3 { return .excited }
        if !s.hasActivity { return .sleepy }
        return .happy
    }
}
