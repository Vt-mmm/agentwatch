import Foundation
import AgentWatchCore

@MainActor
final class ReportDeliveryScheduler {
    static let shared = ReportDeliveryScheduler()
    private var task: Task<Void, Never>?
    private(set) var lastError: String?
    func start() {
        guard task == nil else { return }
        task = Task { [weak self] in
            while !Task.isCancelled {
                await self?.tick()
                do { try await Task.sleep(for: .seconds(30)) } catch { return }
            }
        }
    }
    private func tick() async {
        let store = ReportDeliveryScheduleStore.local
        do {
            guard let item = try store.claimNext() else { return }
            do {
                guard let policy = try ReportTeamPolicyStore.local.load(), policy.digest == item.policyHash else {
                    throw ReportValidationError.invalid("Chính sách thay đổi; cần duyệt lại lịch.")
                }
                let connection = GoogleConnectionStore()
                guard connection.accountKey == item.accountKey else { throw GoogleServiceError.wrongAccount }
                switch item.channel {
                case .gmail:
                    guard let job = try GmailOutboxStore.local.read(item.jobID), job.payloadHash == item.payloadHash,
                          job.employeeID == item.employeeID else { throw GoogleServiceError.conflict }
                    try ReportTeamPolicyStore.local.checkGmail(organizationID: job.organizationID ?? "", employeeID: job.employeeID, destination: job.destination, scheduled: true)
                    let credential = try await connection.credential(requiring: [GoogleScopes.gmailSend])
                    guard Date() < item.expiresAt else { throw ReportValidationError.invalid("Đã quá khoảng giờ được duyệt.") }
                    _ = try await GmailDeliveryService().deliver(jobID: item.jobID, credential: credential, expectedPolicyHash: item.policyHash)
                case .drive:
                    guard let job = try DriveUploadStore.local.read(item.jobID), job.payloadHash == item.payloadHash,
                          job.employeeID == item.employeeID else { throw GoogleServiceError.conflict }
                    try ReportTeamPolicyStore.local.checkDrive(organizationID: job.organizationID ?? "", employeeID: job.employeeID, destination: job.destination, scheduled: true)
                    let credential = try await connection.credential(requiring: [GoogleScopes.driveFile])
                    guard Date() < item.expiresAt else { throw ReportValidationError.invalid("Đã quá khoảng giờ được duyệt.") }
                    _ = try await DriveDeliveryService().deliver(jobID: item.jobID, credential: credential, expectedPolicyHash: item.policyHash)
                }
                try store.finish(item.id, success: true, note: "Đã xử lý; xem receipt riêng của kênh. Không xác nhận người nhận đã đọc.")
            } catch { try store.finish(item.id, success: false, note: error.localizedDescription) }
            lastError = nil
        } catch { lastError = error.localizedDescription }
    }
}
