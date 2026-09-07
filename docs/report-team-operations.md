# Vận hành report cho nhóm

Mở **Soạn report ngày → Vận hành nhóm** để xem chính sách, lịch, ánh xạ tài khoản, đối soát và dọn nội dung. Phase này vận hành trên máy nhân viên; chưa triển khai backend quản trị tập trung hoặc cơ chế gửi khi máy tắt.

## Ownership và chính sách

Nhân viên chịu trách nhiệm xác nhận công việc, bản chốt, người nhận và từng lượt gửi. Chủ chính sách công ty xác định tài khoản Google được dùng, người nhận To/Cc/Bcc, folder Drive, kênh cho phép, quyền đặt lịch, quyền đưa nội dung sang model và thời hạn giữ nội dung.

Contract đóng: `Sources/AgentWatchCore/Resources/report-team-policy-v1.schema.json`. Mẫu cấu hình giả lập: `docs/examples/report-team-policy.example.json`. Không có wildcard người nhận/domain; phải chỉ định email cụ thể. Account key Google lấy từ màn Vận hành nhóm sau đăng nhập (hash client ID và Google subject); đây không phải token.

Ứng dụng có hai cách đọc chính sách:

- **Local operator:** chọn JSON, xem trước đầy đủ đích/quyền, xác nhận owner rồi áp dụng. Chỉ nhận revision tăng dần trong cùng tổ chức. Đây là cấu hình local được người vận hành xác nhận; việc gõ tên owner không phải xác thực danh tính quản trị viên.
- **Managed:** quản trị viên/MDM đặt `/Library/Application Support/AgentWatch/managed-report-policy.json`, file thường thuộc root, không writable bởi group/other, trong thư mục được quản trị bảo vệ. Chính sách managed ưu tiên local; file lỗi/quyền không đúng chặn thao tác, không fallback sang cấu hình rộng hơn. Ứng dụng không tự cài file hệ thống này.

Worker kiểm tra chính sách tại bước gửi, không chỉ ẩn nút UI. Chính sách hết hạn, sai tổ chức/employee/account, kênh tắt hoặc recipient/folder ngoài allowlist đều chặn trước network. Không có chính sách thì vẫn cho gửi thủ công với xác nhận từng bản; không cấp lịch gửi. Sao chép packet cho model trong UI bị chặn nếu policy tắt narrative export; đây không phải cơ chế chống người dùng tự sao chép dữ liệu ngoài ứng dụng.

My Drive thuộc tài khoản nhân viên: khi nghỉ việc, chủ dữ liệu cần xử lý ownership/retention bằng quy trình Workspace của công ty. Shared Drive có thể phù hợp hơn nhưng phải kiểm tra quyền thực; `drive.file` không tự cấp quyền vào mọi Shared Drive. Không nhúng admin key hoặc domain-wide delegation trong app desktop.

## Lịch xử lý

Lịch gắn **một job của một phiên bản đã duyệt**, không phải quyền gửi nội dung tương lai. Ở màn Drive/Gmail, xem PDF và destination, xác nhận nội dung rồi chọn đặt lịch. Nhân viên duyệt thời điểm, múi giờ và khoảng trễ tối đa 1–12 giờ. Chính sách công ty phải cho phép scheduled delivery. Lịch lưu hash policy và payload.

Worker local bắt đầu khi cửa sổ chính của ứng dụng mở; kiểm tra mỗi 30 giây trong thời gian tiến trình còn chạy. Không hứa chính xác từng giây. Cùng job không có hai lịch queued/running. Trước network worker kiểm tra account, scope, policy hiện tại, deadline, payload và approval; Drive còn kiểm tra lại ACL. Policy đổi làm lịch cần review, dù policy mới vẫn cho phép cùng đích.

- Máy ngủ/tắt: không có worker backend thay thế.
- Mở lại trong khoảng giờ đã duyệt: thử một lượt cho đúng job đã duyệt.
- Quá deadline: đánh dấu missed, không tự gửi bù.
- Worker dừng giữa chừng: needsReview; Gmail sending đã mất lease vẫn uncertain, không tự resend.
- 401/403/quota/offline: ghi lý do cần xử lý, không tạo vòng retry. Gmail rate limit tôn trọng Retry-After khi có và không thử trước backoff local.
- Muốn hủy: vào Vận hành nhóm, hủy lịch queued/missed/needsReview của nhân viên. Không thể thu hồi request đã ra mạng bằng nút hủy lịch.

Chưa có standing authorization gửi tự động mỗi ngày, tự đoán ngày nghỉ hoặc tự chọn report mới nhất. Muốn chạy lặp ngày nên thêm quy tắc ngày làm việc/holiday và phạm vi nội dung vào contract rồi nghiệm thu riêng. Hiện người vận hành chọn chính xác bản và thời điểm, tránh báo cáo ngày mới được gửi theo một approval cũ.

## Ánh xạ quota

Mapping gồm tổ chức, provider, source, source account key, capture key, tài khoản chuẩn, khoảng hiệu lực half-open, người xác nhận và thời điểm xác nhận. Cùng nhãn tài khoản **trong cùng tổ chức và provider** tạo cùng canonical account key. Chỉ map sau khi operator xác nhận tài khoản thực; không suy từ tên máy/email/file.

Đối với Claude statusline không có account identity, mapping phải bám đúng session capture key và khoảng thời gian. Khi tài khoản thay đổi tạo khoảng mới không chồng lấn; không ghi đè mapping cũ. Codex hoặc adapter Pi có source account key khác cũng cần xác nhận rõ nếu muốn gộp. Pi không có quota chung: mapping không tạo dữ liệu provider đang thiếu.

UI/report lấy snapshot mới nhất theo account và **bucket ID**; không cộng phần trăm. Hai bucket 5 giờ/7 ngày hoặc model khác nhau vẫn riêng. Nguồn chưa map giữ riêng. Mapping mới chỉ ảnh hưởng bản nháp tạo sau đó; report đã chốt không đổi. Đây không phải mapping chi phí tài khoản cho một nhân viên: quota có thể dùng chung nhiều người/thiết bị.

## Đối soát usage/cost

Màn import nhận một record chuẩn hóa, xem trước hai nguồn rồi lưu immutable. Mẫu: `docs/examples/report-reconciliation.example.json`. Không có API analytics/admin key được gọi tự động. Người phụ trách được phép lấy số liệu tổ chức chuẩn hóa thành hai observation, giữ source, observedAt, account, metric/unit/basis/scope và start/end/timeZone gốc. Không import transcript hoặc token xác thực.

Chỉ tính chênh lệch khi hai bên đều complete và cùng provider/account, kỳ, metric, đơn vị, scope và basis. Khác ngày UTC/GMT+7, một bên partial, analytics khác request ledger hoặc list price khác invoice đều giữ hai giá trị riêng với lý do không so trực tiếp. Không phân bổ một bucket ngày UTC sang ngày công ty theo tỷ lệ. Không sửa tổng report đã chốt từ record đối soát.

## Retention

Nhấn lập danh sách dọn theo retentionDays của policy, xem từng file và tổng byte, rồi xác nhận xóa local. Plan chỉ có hiệu lực 5 phút; kiểm tra lại eligibility và hash trước xóa. Không tự dọn theo timer.

Nội dung đủ tuổi có thể dọn: snapshot không còn được hàng đợi cần xử lý tham chiếu, PDF đã upload, MIME/PDF đã được Gmail chấp nhận hoặc đối chiếu đã gửi. **Luôn giữ** draft, pending/failed/uncertain outbox, lịch queued/running/needsReview, job receipt, mapping và record đối soát. Sau khi dọn payload, xem trước bản cũ có thể không còn file; receipt vẫn ngăn gửi lại một job hoàn tất.

Nội dung preview trong job Gmail hoàn tất cũng được liệt kê để dọn; receipt giữ lại ID, hash, metadata người nhận/tiêu đề và lịch sử đối chiếu. Retention payload không phải xóa toàn bộ dữ liệu cá nhân. Khi công ty cần xóa metadata, cần quy trình quản trị riêng và xử lý đối chiếu/audit trước. Không đụng agent logs, Google Drive hoặc Gmail từ thao tác dọn local.

## Pi telemetry

AgentWatch đã đọc trực tiếp contract journal version 1 của Pi tại `.pi/piagent-state/task-journal/events.jsonl` trong các project được chọn: sequence/hash chain, taskId/taskRunId/sessionId, thời điểm binding. Không cần sửa Pi core hoặc thêm logic nhân viên/Google vào Pi Platform. Journal không phải chứng cứ công việc đạt nghiệm thu; usage chỉ lấy từ runtime JSONL, không cộng thêm từ journal.

Pi 0.84.1 local tạo fork bằng header mới có `parentSession` rồi sao chép entries cũ. Adapter loại message trước/đúng thời điểm fork khỏi usage/prompt mới, đánh dấu partial; local entry IDs được scope theo session. Không đọc đường dẫn parentSession để mở rộng phạm vi thu thập tự động. Sau khi Pi nâng schema, dùng fixtures và kiểm tra writer mới trước khi coi số liệu là chuẩn.
