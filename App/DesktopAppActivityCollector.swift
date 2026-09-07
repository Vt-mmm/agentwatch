import AppKit
import Observation
import AgentWatchCore

@Observable
@MainActor
final class DesktopAppActivityCollector {
    static let shared = DesktopAppActivityCollector()
    private var timer: Timer?
    private var observers: [NSObjectProtocol] = []
    private var last: Date?
    private var employeeID: String?
    private var appID: String?
    private var appName: String?
    private var suspended = false
    private var lastInteraction: DesktopInteractionState = .unknown
    private(set) var status = "Đang chuẩn bị ghi nhận ứng dụng"
    private(set) var error: String?
    private let writer = DispatchQueue(label: "agentwatch.desktop-activity")
    func start() {
        guard timer == nil else { return }
        sample()
        timer = Timer.scheduledTimer(withTimeInterval: 15, repeats: true) { _ in Task { @MainActor in self.sample() } }
        let center = NSWorkspace.shared.notificationCenter
        observers.append(center.addObserver(forName: NSWorkspace.didActivateApplicationNotification, object: nil, queue: .main) { _ in
            Task { @MainActor in self.sample() }
        })
        for name in [NSWorkspace.didWakeNotification, NSWorkspace.sessionDidBecomeActiveNotification] {
            observers.append(center.addObserver(forName: name, object: nil, queue: .main) { _ in
                Task { @MainActor in self.suspended = false; self.last = nil; self.sample() }
            })
        }
        for name in [NSWorkspace.willSleepNotification, NSWorkspace.sessionDidResignActiveNotification] {
            observers.append(center.addObserver(forName: name, object: nil, queue: .main) { _ in
                Task { @MainActor in self.sample(); self.suspended = true; self.last = nil }
            })
        }
    }
    func sample() {
        let now = Date(), identity = SupervisorLockStore.shared.collectionIdentity
        // kCGAnyInputEventType is UINT32_MAX, not CGEventType.null (event zero).
        let interaction = DesktopInteractionState.observed(idleSeconds: CGEventSource.secondsSinceLastEventType(.combinedSessionState, eventType: CGEventType(rawValue: UInt32.max)!))
        if let last, let employeeID, let appID, let appName, !suspended,
           identity?.employeeID == employeeID, now.timeIntervalSince(last) <= 60 {
            let row = DesktopAppInterval(employeeID: employeeID, bundleID: appID, name: appName, start: last, end: now,
                interaction: interaction == lastInteraction ? interaction : .unknown)
            writer.async {
                do { try DesktopAppActivityStore.local.append(row) }
                catch { let message = error.localizedDescription; Task { @MainActor in self.error = message } }
            }
        }
        let foreground = NSWorkspace.shared.frontmostApplication
        last = identity == nil || suspended ? nil : now
        employeeID = identity?.employeeID
        appID = foreground?.bundleIdentifier ?? foreground?.localizedName.map { "local-app:" + $0 }
        appName = foreground?.localizedName
        lastInteraction = interaction
        status = identity == nil ? "Chưa gắn key cho máy; chưa ghi nhận ứng dụng" : suspended ? "Tạm dừng khi máy ngủ hoặc phiên không hoạt động" : "Đang ghi ứng dụng · " + (appName ?? "Chưa rõ app") + " · " + interaction.label
    }
    func flush() async {
        sample()
        await withCheckedContinuation { continuation in writer.async { continuation.resume() } }
    }
    func stopAndFlush() {
        sample(); timer?.invalidate(); timer = nil
        writer.sync {}
    }
}
