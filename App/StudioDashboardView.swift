import SwiftUI
import AgentWatchCore

/// Personal usage: three numbers, remaining quota, then models and recent
/// requests side by side. Accounting details stay in a tooltip.
struct StudioDashboardView: View {
    @Environment(StudioConnectionStore.self) private var studio

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            if let error = studio.dashboardError, error != studio.error {
                Text(error.localizedDescription).font(ClaudeFont.body(12)).foregroundStyle(Claude.orange)
            }
            if let report = studio.dashboard {
                tiles(report)
                quota(report)
                StudioColumns(trailingWidth: 320) {
                    requests(report.recent)
                } trailing: {
                    models(report.month)
                }
                footer(report)
            } else if studio.dashboardState == .loading {
                ProgressView("Đang tải usage…").controlSize(.small)
            } else {
                Text("Chưa có dữ liệu usage từ Studio.").font(ClaudeFont.body(12)).foregroundStyle(Claude.textMuted)
            }
            if studio.cacheUnavailable {
                Text("Không lưu được bản cache trên máy; số liệu có thể mất khi mở lại app.").font(ClaudeFont.body(11)).foregroundStyle(Claude.orange)
            }
        }
    }

    private func tiles(_ report: StudioDashboardSnapshot) -> some View {
        HStack(spacing: 12) {
            tile("Hôm nay", StudioFormat.tokens(report.today.summary.confirmed.total_tokens), "\(report.today.summary.requests.formatted) request")
            tile("Tháng này", StudioFormat.tokens(report.month.summary.confirmed.total_tokens), "\(report.month.summary.requests.formatted) request")
            tile("Chưa xác nhận", report.month.summary.unresolved_requests.formatted, report.month.summary.disputed_requests.value == "0" ? "request trong tháng" : "gồm \(report.month.summary.disputed_requests.formatted) cần đối soát")
        }
    }
    private func tile(_ label: String, _ value: String, _ detail: String) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(label).font(ClaudeFont.label(11)).foregroundStyle(Claude.textMuted)
            Text(value).font(.system(size: 22, weight: .semibold)).monospacedDigit().lineLimit(1).minimumScaleFactor(0.6).textSelection(.enabled)
            Text(detail).font(ClaudeFont.body(10.5)).foregroundStyle(Claude.textMuted).lineLimit(1)
        }.frame(maxWidth: .infinity, alignment: .leading).studioCard(padding: 12)
    }

    @ViewBuilder private func quota(_ report: StudioDashboardSnapshot) -> some View {
        let summaries = StudioQuotaSummary.from(report.quota)
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                SectionLabel(text: "Hạn mức key")
                Spacer()
                if case .available(let models) = studio.snapshot?.models, models.count > 1 {
                    Picker("Model", selection: Binding(get: { studio.quotaModelID ?? models[0].id }, set: { id in Task { await studio.selectQuotaModel(id) } })) {
                        ForEach(models) { Text($0.displayName.isEmpty ? $0.id : $0.displayName).tag($0.id) }
                    }.labelsHidden().controlSize(.small).frame(maxWidth: 200).disabled(studio.dashboardState == .loading)
                        .help("Hạn mức tổng giống nhau cho mọi model; chọn model để xem thêm hạn mức riêng nếu có.")
                }
            }
            if let quota = report.quota, !quota.policy_allowed {
                Text("Key không được dùng model này.").font(ClaudeFont.body(12)).foregroundStyle(Claude.orange)
            } else if summaries.isEmpty {
                Text(report.quotaError?.localizedDescription ?? "Studio chưa trả hạn mức cho key này.").font(ClaudeFont.body(12)).foregroundStyle(Claude.textMuted)
            } else {
                ViewThatFits(in: .horizontal) {
                    HStack(alignment: .top, spacing: 24) { ForEach(summaries, id: \.period) { StudioQuotaBar(summary: $0) } }
                    VStack(alignment: .leading, spacing: 10) { ForEach(summaries, id: \.period) { StudioQuotaBar(summary: $0) } }
                }
            }
        }.studioCard(padding: 12)
    }

    private func models(_ overview: StudioOverview) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            SectionLabel(text: "Theo model · tháng này")
            if overview.models.isEmpty { Text("Chưa có request.").font(ClaudeFont.body(12)).foregroundStyle(Claude.textMuted) }
            ForEach(Array(overview.models.prefix(6).enumerated()), id: \.offset) { _, model in
                HStack(alignment: .firstTextBaseline) {
                    VStack(alignment: .leading, spacing: 1) {
                        Text(model.label).font(ClaudeFont.body(12)).lineLimit(1)
                        Text("\(model.requests.formatted) request").font(ClaudeFont.label(10)).foregroundStyle(Claude.textMuted)
                    }
                    Spacer()
                    Text(StudioFormat.tokens(model.confirmed.total_tokens)).font(ClaudeFont.mono(12)).monospacedDigit()
                }
            }
        }.studioCard(padding: 12)
    }

    private func requests(_ report: StudioUsageReport) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            SectionLabel(text: "Request gần đây")
            if report.requests.isEmpty { Text("Chưa có request trong tháng.").font(ClaudeFont.body(12)).foregroundStyle(Claude.textMuted) }
            ForEach(report.requests.prefix(10)) { request in
                HStack(spacing: 8) {
                    Text(StudioFormat.time(request.created_at)).font(ClaudeFont.mono(10.5)).foregroundStyle(Claude.textMuted).frame(width: 78, alignment: .leading)
                    Text(request.model_id).font(ClaudeFont.body(12)).lineLimit(1)
                    Spacer(minLength: 6)
                    Text(StudioFormat.tokens(request.confirmed.total_tokens)).font(ClaudeFont.mono(11.5)).monospacedDigit()
                    status(request.accounting_status)
                }
                .help("Mã request: \(request.id.uuidString.lowercased())\nInput \(request.confirmed.input_tokens?.formatted ?? "—") · Output \(request.confirmed.output_tokens?.formatted ?? "—")")
                .contextMenu { Button("Sao chép mã request") { NSPasteboard.general.clearContents(); NSPasteboard.general.setString(request.id.uuidString.lowercased(), forType: .string) } }
            }
        }.studioCard(padding: 12)
    }
    @ViewBuilder private func status(_ value: String) -> some View {
        switch value {
        case "confirmed": Image(systemName: "checkmark.circle").foregroundStyle(Claude.live).help("Đã xác nhận").font(.system(size: 11))
        case "disputed": Image(systemName: "exclamationmark.circle").foregroundStyle(Claude.orange).help("Cần đối soát lại").font(.system(size: 11))
        default: Image(systemName: "clock").foregroundStyle(Claude.textMuted).help("Chưa xác nhận").font(.system(size: 11))
        }
    }

    private func footer(_ report: StudioDashboardSnapshot) -> some View {
        HStack(spacing: 6) {
            if studio.dashboardState == .loading { ProgressView().controlSize(.mini) }
            if studio.dashboardState == .stale { Image(systemName: "clock.arrow.circlepath").foregroundStyle(Claude.orange) }
            Text("Studio ledger · \(report.today.timezone) · cập nhật \(StudioFormat.time(report.fetchedAt))")
            Image(systemName: "info.circle")
                .help("Token xác nhận chỉ cộng request có usage đầy đủ; “—” là chưa rõ, không phải 0. Input đã gồm cache, output đã gồm reasoning. Token ghi sổ tháng này: \(report.month.summary.charged_tokens.formatted). Bao gồm key cũ đã thay của bạn.")
        }.font(ClaudeFont.body(10.5)).foregroundStyle(Claude.textMuted)
    }
}
