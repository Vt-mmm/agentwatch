import SwiftUI
import AgentWatchCore

struct StudioDashboardView: View {
    @Environment(StudioConnectionStore.self) private var studio
    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack {
                Text("Usage cá nhân").font(ClaudeFont.heading(22))
                Spacer()
                if studio.dashboardState == .loading { ProgressView().controlSize(.small) }
                if studio.dashboardState == .stale { Label("Bản lưu · dữ liệu cũ", systemImage: "clock").foregroundStyle(Claude.orange) }
            }
            if let error = studio.dashboardError, error != studio.error { Text(error.localizedDescription).foregroundStyle(Claude.orange) }
            if let report = studio.dashboard {
                Text("\(report.identity.user.displayName) · Nguồn: Studio ledger · \(report.today.timezone)")
                    .font(ClaudeFont.body(12)).foregroundStyle(Claude.textMuted)
                if studio.dashboardState == .loading { Text("Đang tải; số bên dưới là lần cập nhật trước.").font(.caption).foregroundStyle(Claude.orange) }
                usageCards(report)
                quota(report)
                models(report.month)
                requests(report.recent)
                Text("Các phần được đọc ở những thời điểm riêng. Input đã gồm cache; output đã gồm reasoning. Usage chưa rõ không được coi là 0. Chi phí và dung lượng thuê bao chưa có dữ liệu xác minh.")
                    .font(ClaudeFont.body(12)).foregroundStyle(Claude.textMuted)
            } else if studio.dashboardState != .loading {
                Text("Chưa có dữ liệu usage đã xác minh từ Studio.").foregroundStyle(Claude.textMuted)
            }
            if studio.cacheUnavailable {
                Text("Không đọc/lưu được bản cache trên máy. Dữ liệu đang hiển thị có thể không còn khi mở lại app.")
                    .font(ClaudeFont.body(12)).foregroundStyle(Claude.orange)
            }
        }
    }
    private func usageCards(_ report: StudioDashboardSnapshot) -> some View {
        LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], alignment: .leading, spacing: 12) {
            metric("Ngày · token xác nhận", value: report.today.summary.confirmed.total_tokens?.formatted ?? "—", detail: "Ngày \(date(report.today.from, zone: report.today.timezone)) · \(report.today.summary.requests.formatted) request · cập nhật \(time(report.today.observed_at))")
            metric("Tháng · token xác nhận", value: report.month.summary.confirmed.total_tokens?.formatted ?? "—", detail: "Từ \(date(report.month.from, zone: report.month.timezone)) · cập nhật \(time(report.month.observed_at))")
            metric("Chưa xác nhận · trong kỳ", value: report.month.summary.unresolved_requests.formatted, detail: "Gồm \(report.month.summary.disputed_requests.formatted) request có số liệu tranh chấp")
            metric("Token đã ghi sổ · trong kỳ", value: report.month.summary.charged_tokens.formatted, detail: "Có thể gồm charge đang tranh chấp; không cộng vào token xác nhận")
        }
    }
    private func metric(_ label: String, value: String, detail: String) -> some View {
        VStack(alignment: .leading, spacing: 7) {
            Text(label).font(ClaudeFont.label(12)).foregroundStyle(Claude.textMuted)
            Text(value).font(.system(size: 24, weight: .semibold)).textSelection(.enabled)
                .minimumScaleFactor(0.5).lineLimit(1)
            Text(detail).font(ClaudeFont.body(11)).foregroundStyle(Claude.textMuted)
        }.frame(maxWidth: .infinity, minHeight: 90, alignment: .topLeading).claudeCard()
    }
    private func quota(_ report: StudioDashboardSnapshot) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            SectionLabel(text: "Hạn mức của key hiện tại")
            if case .available(let models) = studio.snapshot?.models, !models.isEmpty {
                Picker("Model", selection: Binding(get: { studio.quotaModelID ?? models[0].id }, set: { id in Task { await studio.selectQuotaModel(id) } })) {
                    ForEach(models) { model in Text(model.displayName).tag(model.id) }
                }.disabled(studio.dashboardState == .loading)
            } else if let model = report.quotaModel { Text(model.displayName).font(ClaudeFont.heading()) }
            if let quota = report.quota {
                if !quota.policy_allowed { Text("Policy hiện tại không cho phép model này.").foregroundStyle(Claude.orange) }
                else if quota.windows.isEmpty { Text("Studio không trả về cửa sổ hạn mức nào; không suy ra hạn mức vô tận.") }
                ForEach(quota.windows) { window in
                    VStack(alignment: .leading, spacing: 5) {
                        let scope = quota.policies.first(where: { $0.id == window.policy_id })?.scope ?? "unknown"
                        Text("\(scopeLabel(scope)) · \(window.period == "day" ? "Ngày" : "Tháng") · \(window.model_id ?? "Tất cả model")").font(ClaudeFont.heading(13))
                        Text("Còn \(window.remaining_tokens.formatted) / \((try? StudioCount(String(window.tokens)).formatted) ?? "—") token")
                            .font(ClaudeFont.body()).textSelection(.enabled)
                        Text("Đã xác nhận: \(window.confirmed_tokens.formatted) · Đang giữ: \(window.reserved_tokens.formatted)")
                            .font(ClaudeFont.body(12)).foregroundStyle(Claude.textMuted)
                        Text("\(time(window.starts_at)) → \(time(window.ends_at)) · múi giờ policy: \(window.timezone)")
                            .font(ClaudeFont.label(10)).foregroundStyle(Claude.textMuted)
                    }
                    Divider()
                }
                Text("Cập nhật \(time(quota.observed_at)). Không cộng các dòng hạn mức. Phần đang giữ có thể bao gồm usage pending; Studio kiểm tra lại khi gửi request.")
                    .font(ClaudeFont.body(11)).foregroundStyle(Claude.textMuted)
            } else {
                Text(report.quotaError?.localizedDescription ?? "Chưa có model khả dụng để kiểm tra quota. Usage cá nhân vẫn độc lập với danh sách model.")
                    .font(ClaudeFont.body()).foregroundStyle(Claude.textMuted)
            }
        }.claudeCard()
    }
    private func models(_ overview: StudioOverview) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            SectionLabel(text: "Theo model · trong kỳ · tối đa 10 model")
            if overview.models.isEmpty { Text("Chưa có request trong kỳ này.").foregroundStyle(Claude.textMuted) }
            ForEach(Array(overview.models.enumerated()), id: \.offset) { _, model in
                HStack {
                    VStack(alignment: .leading) {
                        Text(model.label).font(ClaudeFont.body())
                        Text("\(model.requests.formatted) request · \(model.unresolved_requests.formatted) chưa xác nhận").font(ClaudeFont.label()).foregroundStyle(Claude.textMuted)
                    }
                    Spacer()
                    Text(model.confirmed.total_tokens?.formatted ?? "—").monospacedDigit()
                }
            }
            Text("Token xác nhận · cập nhật \(time(overview.observed_at))").font(ClaudeFont.label()).foregroundStyle(Claude.textMuted)
        }.claudeCard()
    }
    private func requests(_ report: StudioUsageReport) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            SectionLabel(text: "20 request gần nhất · trong kỳ")
            if report.requests.isEmpty { Text("Chưa có request trong kỳ này.").foregroundStyle(Claude.textMuted) }
            ForEach(report.requests) { request in
                VStack(alignment: .leading, spacing: 4) {
                    HStack {
                        Text(request.model_id).font(ClaudeFont.body())
                        Spacer()
                        Text(request.confirmed.total_tokens?.formatted ?? "—").monospacedDigit()
                        Text(status(request.accounting_status)).font(ClaudeFont.label()).foregroundStyle(request.accounting_status == "confirmed" ? Claude.live : Claude.orange)
                    }
                    Text("\(time(request.created_at)) · \(request.provider) · ghi sổ \(request.charged_tokens.formatted) token")
                        .font(ClaudeFont.label()).foregroundStyle(Claude.textMuted)
                    Text(request.id.uuidString.lowercased()).font(ClaudeFont.mono(10)).foregroundStyle(Claude.textMuted).textSelection(.enabled)
                }
                Divider()
            }
            Text("Nguồn Studio ledger · cập nhật \(time(report.observed_at)). Bao gồm các key khác/đã rotate của cùng nhân viên.")
                .font(ClaudeFont.label()).foregroundStyle(Claude.textMuted)
        }.claudeCard()
    }
    private func status(_ value: String) -> String {
        switch value { case "confirmed": "Xác nhận"; case "disputed": "Tranh chấp"; default: "Pending" }
    }
    private func scopeLabel(_ value: String) -> String {
        switch value { case "org": "Tổ chức"; case "team": "Nhóm"; case "user": "Nhân viên"; case "key": "Key"; default: "Phạm vi chưa rõ" }
    }
    private func time(_ value: Date) -> String { value.ISO8601Format() }
    private func date(_ value: Date, zone: String) -> String {
        let formatter = DateFormatter(); formatter.dateFormat = "dd/MM/yyyy"; formatter.timeZone = TimeZone(identifier: zone)
        return formatter.string(from: value)
    }
}
