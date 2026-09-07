# Daily report implementation

Approved scope: research dated 2026-09-06 in `../../plans/reports/agentwatch-daily-report-research-2026-09-06/`. Work sequentially; no subagents. Do not overwrite unrelated working-tree changes.

## Phase gates

- [x] 1. Accurate data: half-open reporting periods; request ledger; exact model pricing and provenance/coverage; source deduplication and parent/fork handling; accounting fixtures; provider quota snapshots with capability checks.
- [x] 2. Daily report: employee profile, work items and evidence, Pi task journal linking, manual notes, editable review, immutable revisioned snapshots, manager renderers and PDF, historical export, validated optional model narrative.
- [x] 3. Drive implementation: desktop OAuth/Keychain, explicit folder permissions, durable upload IDs, receipts and recovery, report UI integration. Live gate below remains pending.
- [x] 4. Gmail implementation: MIME renderer, exact preview/approval, durable outbox, per-channel recovery, uncertain-send handling, report UI integration. Live gate below remains pending.
- [x] 5. Team implementation: organization policy, account mapping, reconciliation, approved schedules for fixed reviewed jobs, retention and ownership, operational documentation and acceptance audit.
- [ ] Live pilot: company OAuth login/refresh/revocation, recipient Drive access, approved synthetic Gmail delivery and scheduled delivery; actual account quota capability. Deferred until the operator provides configuration after implementation.

## Verification requirements

Unit fixtures cover each accounting/identity/date invariant and delivery failure state; app build checks integration outside the Swift package. End-to-end Google verification requires a company OAuth client, authorized test account/folder and an explicitly selected test recipient. An implementation or mock success does not prove live Google acceptance.

The production implementation must preserve unknown/partial data, not infer employee productivity or hours from token/session activity, and never turn model output into authority to send/share. Runtime files, credentials and captured logs stay outside the repository.

## Current state

Phases 1–5 implemented for the local desktop scope. On 2026-09-06, 108 Swift package tests passed and the macOS Debug app build succeeded with the cached Sparkle dependency. No live provider quota request, Google upload, or email has been performed. Live acceptance is intentionally separate from implementation completion.

The operator will provide Google Desktop OAuth client and test destinations **after implementation**. Continue through all implementation phases with fake transport tests; defer live acceptance rather than repeatedly requesting setup.

### Phase 1 implementation evidence

- `ReportTime` provides half-open periods; all readers, CLI and app consumers use `Range<Date>`.
- `UsageLedger` deduplicates request revisions, normalizes cache/reasoning once, retains partial cost and validates numeric buckets. Pi cost is an agent estimate. Exact model IDs and supported per-request context/tier rates use a dated list-price catalog, not historical invoices.
- Codex counters preserve known segments, exclude ambiguous resets, flag missing baselines and inherited fork history. Cumulative deltas cannot assert a request crossed the long-context pricing threshold.
- `SessionAccounting` merges live/archive session copies and aggregates unique usage entries. Full coaching scan visits child logs and configurable roots without an mtime cutoff; child prompts are excluded from employee prompt history.
- `SourceManifest` records file digest, size, readability and malformed records. Export must preserve these warnings and must not claim unobserved employee work is complete.
- `QuotaSnapshot` keeps provider percentages independent of context/cost, optional account mapping, expiry/reset freshness and normalized local history. Claude statusline capture, read-only Codex app-server exchange and a provider quota card are connected. Pi explicitly reports that no universal Pi quota exists.

### Price sources and limits

Catalog checked 2026-09-06 against official [OpenAI pricing](https://developers.openai.com/api/docs/pricing), [GPT-6 Astra](https://developers.openai.com/api/docs/models/gpt-6-astra), [Sol](https://developers.openai.com/api/docs/models/gpt-5.6-sol), [Terra](https://developers.openai.com/api/docs/models/gpt-5.6-terra), [Luna](https://developers.openai.com/api/docs/models/gpt-5.6-luna), and [Claude pricing](https://platform.claude.com/docs/en/about-claude/pricing). OpenAI models above have a per-request 272K threshold; supported Claude 4.6+ models have standard pricing through 1M context. Unsupported routing, variants or tiers remain unavailable. Regional contracts, hosted tool charges, subscriptions and invoices are not reconstructed from token logs.

Codex wire contract was checked against the locally generated 0.153.4 app-server schema. Claude quota is detected from actual [statusline fields](https://code.claude.com/docs/en/statusline), never assumed solely from the installed version.


### Phase 2 verification (2026-09-06)

72 package tests passed; the macOS Debug application built successfully after the final UI/schema changes. Tests cover confirmation gates, closed schemas, narrative field/reference rejection, immutable revisions and metadata/content hashes, tamper detection, draft recovery, historical quota exclusion, Pi journal hash chains, task transitions with unallocated usage, manual merges, share redaction/HTML/CSV handling and selectable Vietnamese PDF pagination.

The one-page synthetic PDF and all three pages of the long synthetic PDF were rendered with Poppler and visually inspected: no clipping, overlap or missing Vietnamese glyphs. Test previews are in `/private/tmp/agentwatch-report-preview/`; they contain no employee data. Usage instructions are in `docs/daily-reports.md`.

The optional model path is deliberately operator-driven: copy the redacted prompt/evidence packet into a coding agent, paste its JSON suggestion for strict validation, and review. AgentWatch does not silently send source logs to a model or authorize external delivery. Gợi ý không hợp lệ giữ nguyên bản nháp; không có vòng sửa model tự động.

### Phase 3 implementation note

Google's installed-app documentation checked again on 2026-09-06 states incremental authorization is not supported for installed apps. Request the complete selected scope set per browser consent flow; when enabling an additional channel, reauthorize with the complete set and verify returned scopes/account. Do not rely on `include_granted_scopes` to broaden an installed-app grant.


### Phase 3 implementation verification (2026-09-06)

Drive implementation and mock verification complete; phase 4 is in progress. 83 package tests passed and the macOS app build succeeded. New tests cover PKCE/state/callback binding, returned scope and verified account checks, token refresh preservation, durable file/folder IDs after timeouts, exact byte verification, duplicate-worker rejection, payload/employee/account approval binding, folder ACL changes, modified queued PDFs and persisted quota backoff.

The Desktop OAuth flow uses the system browser and an explicit IPv4 loopback listener, never an embedded sign-in browser. Credentials/client configuration secrets use Keychain; public client/account display metadata uses app preferences. No external account was used during implementation.

The Drive adapter supports binary PDF multipart uploads up to 5 MB, with no Google Docs conversion. It can create an app-owned folder with a preallocated ID or use an existing folder already authorized to this app. It does not claim an arbitrary manually entered folder ID grants `drive.file` access, and does not silently broaden the OAuth scope. Folder permissions are shown in review and hashed into upload approval; no sharing permissions are created by uploading.

The phase 3 live gate remains unchecked until the operator supplies the OAuth client/test account/folder and recipient access is verified. The operator explicitly asked to provide those after all implementation, so this does not block implementing phase 4 or 5.

### Phase 4 implementation verification (2026-09-06)

93 package tests passed; macOS app build succeeded. The 10 Gmail tests exercise UTF-8 MIME/PDF/recipients, strict header validation, exact durable payload reuse, accepted receipts, timeouts, abandoned sending leases, 5xx/malformed success, quota backoff, account/payload/approval mismatches and explicit manual reconciliation. Python's independent email parser also validated the synthetic MIME, encoded Unicode subject, To/Cc/Bcc, plain/HTML body and one intact PDF attachment.

Gmail uses an independently approved local outbox and `gmail.send` only. Default delivery includes a PDF attachment, so Drive access is not assumed. The Drive completion screen can open Gmail review without triggering another upload. HTTP acceptance is labeled as acceptance, never as recipient delivery/read. Unknown send outcomes never automatically retry, including expired worker leases. Live acceptance is deferred per operator instruction. Setup and recovery instructions: `docs/google-report-delivery.md`.

### Phase 5 implementation verification (2026-09-06)

Closed policy schema, local reviewed import and root-owned managed policy precedence; delivery guards enforce organization/employee/account, time zone, channel and destination allowlists. Optional narrative packet export follows policy. A changed/expired/broken policy blocks rather than falling back.

Explicit source/account/time-bound quota mappings keep unknown sources separate and retain latest values per bucket without adding percentages. Reconciliation records preserve original periods/units/bases and refuse fabricated UTC/local prorating or estimate/invoice comparisons. One-time schedules bind fixed reviewed jobs, policy and payload hashes, with bounded lateness; offline/abandoned execution becomes missed/needsReview instead of blind catch-up. Retention previews exact eligible local files/content, preserves pending work/receipts and clears expired email preview content after explicit review.

Eleven team tests plus Gmail Retry-After and cross-channel recovery tests were added. Final accounting review added a Pi fork regression and fixed invalid usage records preventing partial daily report sealing; the report now includes per-agent/provider/model breakdown. Native PDF QA was repeated for the one-page sample and all four pages of the expanded sample.

Operational instructions: `docs/report-team-operations.md`. Contract acceptance matrix and deliberate scope choices: `docs/daily-report-acceptance.md`. Synthetic PDF, HTML and MIME previews are in `../../plans/reports/agentwatch-daily-report-research-2026-09-06/implementation-preview/`. No production account, actual scheduled delivery, retention cleanup of user data, Git commit or publish occurred.

### Enrollment key → report name → Drive folder (2026-09-07)

Implemented the requested reuse of existing app-open keys. Successful enrollment supplies a stable derived employee ID and the key's assigned label for report/profile and folder naming. Authentication keys/hashes are not written into report metadata. Names can change without changing the employee identity or an existing Drive folder binding.

Per-organization/employee/Google-account bindings remember a verified existing folder or a newly created named child under an explicitly configured, accessible company Reports folder. UI prevents silent rebinding; the delivery service also checks the binding for key-derived employee IDs. Folder creation persists its reserved ID and uses identity plus parent for recovery, including when the folder or label is renamed. No name-based search or automatic creation occurs on app login.

113 package tests passed and the Debug macOS build succeeded. Five new tests cover derived identity, account/organization separation, rename-safe bindings, refusal to redirect a bound key or reuse another key's folder, parent-scoped creation/recovery and wrong-parent rejection. Google live tests remain deferred; this work did not connect or create real Drive folders. Existing manual profiles and previously sealed reports are preserved; create a new draft to adopt the key-derived profile. Google Picker remains a separate UI addition.

## Bổ sung tiêu chí prompt/task và app — 2026-09-07

Đã thêm liên kết prompt với task theo thời điểm journal hoặc nhân viên chọn, đánh giá phạm vi có lý do, xem prompt gốc cục bộ và tóm tắt riêng cho bản chia sẻ. Đổi/gộp task reset đánh giá phạm vi. Thống kê app theo ngày dùng prompt đã lọc/trừ lặp và usage ledger; không lấy tổng prompt suốt đời session.

Màn hình editor và PDF/HTML/Markdown/CSV/JSON dùng các mục mới. Snapshot cũ giữ nguyên content seal nhờ phần dữ liệu bổ sung tùy chọn. Phạm vi app hiện gồm coding agent có log, chưa thu ứng dụng toàn máy. Xem [chi tiết](report-daily-activity.md).

Kiểm tra cuối: 119 tests đạt (6 tests mới), build Debug macOS thành công, diff không có lỗi whitespace. PDF mẫu giả lập render và kiểm tra trực quan tiếng Việt, không cắt chữ. Chưa phát hành ứng dụng hoặc gọi Google thực tế.

## Xuất một nút và ứng dụng toàn máy — 2026-09-07

Theo yêu cầu mới, thêm **Xuất report ngày** trong Coaching: chọn ngày, tự đọc mọi nguồn coding agent, tự nhóm yêu cầu và lưu PDF vào Documents/AgentWatch Reports. Không bắt điền tổ chức, sửa từng task, gắn từng prompt hoặc chốt xác nhận. Report mang nhãn tự động, không giả xác nhận nhân viên và không gửi Google. Luồng chỉnh sửa thủ công vẫn có qua **Chỉnh sửa report…**.

Thêm collector tên ứng dụng/foreground interval từ NSWorkspace khi AgentWatch chạy và key được xác thực, ghép vào report theo ngày. Không đọc nội dung ứng dụng và không hồi dựng lịch sử trước lúc thu thập. Xem [hướng dẫn xuất tự động](automatic-daily-report.md).

125 tests đạt; build Debug macOS thành công. Đã kiểm tra PDF mẫu bằng render hai trang, kiểm tra việc lưu PDF thật không ghi đè, biên ngày/cutoff và tách lịch sử theo key. Bản thử mới đã được mở trên máy.


## 2026-09-07 — Report chi tiết và ghi ứng dụng từ lúc đăng nhập

- Tổng quan trích yêu cầu cụ thể, phụ lục prompt đầy đủ sau lọc, metadata task/phiên/phạm vi và giờ/loại/trạng thái phản hồi công cụ. Không đưa lệnh thực thi hoặc private reasoning vào bản quản lý.
- Phân biệt prompt nhân viên và Codex goal continuation/context. Báo cáo thử cho 61 user-message events tách thành 18 prompt nhân viên + 43 lượt tự động/ngữ cảnh; không coi agent tự chạy ban đêm là nhân viên thao tác.
- PDF A4 mới có ô chỉ số, mục đánh số, thanh tỷ lệ app, header/footer và ngắt trang. Prompt dài được kiểm tra giữ tới ký tự cuối. Ảnh đính kèm giữ tên tệp và nhãn ảnh, bỏ bao ngoài/đường dẫn tạm.
- Collector bắt đầu ở app delegate, dùng danh tính máy đã enroll trong lúc UI chờ key; quyền xem/xuất vẫn giữ xác thực lượt mở. Khoảng tương tác gần đây/idle/chưa rõ lấy mẫu khoảng 15 giây, không đọc phím gõ. Dữ liệu cũ giữ unknown; khoảng sleep/gap không được tự lấp.
- Cài bản local tại `/Users/vtamm/Applications/AgentWatch.app`. Đã quan sát UI khóa báo “Tự mở khi đăng nhập: đã bật”, và file lịch sử tiếp tục có mẫu `recentInput` khi chưa nhập key cho lần chạy mới. Chưa kiểm thử đăng xuất/khởi động lại máy thật; không tuyên bố đã qua kiểm tra đó.
- Google upload/Gmail chưa kiểm tra thực tế vì cấu hình công ty vẫn được người dùng hẹn gửi sau.
- Kiểm tra cuối: 130 tests, 0 failures (09:50:49); native build đạt; binary bản cài trùng bản build. PDF thật chốt 09:49:22 có 18 prompt nhân viên, 43 lượt tự động/ngữ cảnh, 9 app; 15 trang đã render và kiểm tra. Bản mẫu lưu `~/Documents/AgentWatch Reports/Report-chi-tiet-2026-09-07-0950.pdf`, kèm HTML. Dữ liệu thực tế có cả recentInput và idle; mẫu cũ vẫn giữ unknown. Không còn bao ngoài ảnh hoặc đường dẫn ảnh tạm trong PDF mẫu.
