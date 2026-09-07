# Báo cáo công việc ngày

Sau khi chốt phiên bản, dùng **Xuất / gửi** để lưu PDF/HTML/Markdown/CSV/JSON, upload Drive hoặc gửi Gmail. Xem [hướng dẫn Google](google-report-delivery.md), [vận hành nhóm](report-team-operations.md) và [ma trận nghiệm thu](daily-report-acceptance.md). Nút **Vận hành nhóm** nằm ở đầu màn soạn report.

Từ 2026-09-07, key mở app đã xác thực tự điền mã nhân viên ổn định và tên được gán trong danh mục key. Ví dụ key mang nhãn “Quang - TW - FE” cho tên hồ sơ/thư mục “Quang - TW - FE”. Không đưa chuỗi key hoặc hash xác thực vào tên thư mục hay report. Khi đang dùng hồ sơ theo key, hai trường mã/tên không sửa thủ công. Report cũ vẫn giữ hồ sơ và nội dung đã chốt; tạo bản mới để dùng hồ sơ theo key.

Trong tab Coaching, chọn **Soạn report ngày**. Điền tổ chức, mã nhân viên, họ tên và múi giờ. Chọn ngày hôm nay hoặc ngày cần xuất bù rồi bấm **Đọc log, tạo bản nháp**. Mỗi report ghi rõ kỳ, giờ chốt và phiên bản; xuất bù không thay đổi bản đã chốt trước đó.

Nếu dự án dùng Pi Task Journal, chọn thư mục dự án trước khi đọc log. AgentWatch chỉ đọc `.pi/piagent-state/task-journal/events.jsonl` trong các dự án được chọn. Nhật ký phải có schema/hash chain phù hợp. Liên kết journal giúp chia usage khi một session chuyển task; tên session đơn thuần chỉ là gợi ý và không đủ để phân bổ token.

## Rà soát công việc

Với mỗi đầu việc, bổ sung kết quả, vướng mắc và việc tiếp theo. Có thể thêm công việc ngoài coding agent, gộp nhiều session vào một đầu việc, thêm link bằng chứng HTTPS hoặc thời gian tự nhập. Thời gian này là số nhân viên khai báo; AgentWatch không suy giờ công hay năng suất từ khoảng cách giữa các sự kiện.

Các trạng thái Hoàn thành, Chờ review và Đã dừng cần nhân viên xác nhận. Kết quả hoàn thành phải có mô tả và bằng chứng tham chiếu. Phản hồi của công cụ chỉ chứng minh đã thu phản hồi; không tự chứng minh test thành công, deploy xong hay đạt yêu cầu nghiệp vụ. Ghi chú xuất bù lưu thời điểm nhập thực và ngày công việc được khai báo riêng.

Bản nháp tự lưu tại `~/Library/Application Support/AgentWatch/reports/drafts/`. Khi sửa nội dung đầu việc hoặc gộp đầu việc, xác nhận cũ bị hủy. Tick xác nhận rà soát toàn bộ report rồi bấm **Chốt phiên bản**. Mỗi lần chốt sinh revision mới. Có thể mở phiên bản cũ, sửa và chốt thành bản mới.

## Đầu ra

- PDF: A4, có phân trang và số trang; chữ tiếng Việt có thể chọn/copy.
- HTML: bố cục đọc trên màn hình và in, không tải tài nguyên ngoài.
- Markdown: nội dung report để lưu tài liệu.
- CSV: một hàng mỗi đầu việc, có chống diễn giải ô văn bản thành công thức.
- JSON: bản dữ liệu đã lọc cho quản lý; không phải JSON snapshot nội bộ.

Bản cho quản lý chỉ có nội dung được chọn. Không xuất nguyên transcript, private reasoning, ảnh/tool output, đường dẫn nguồn trên máy hoặc token đăng nhập. Có lớp che các mẫu thông tin nhạy cảm thông dụng, nhưng nhân viên vẫn cần đọc bản xem trước và xác nhận link phù hợp trước khi gửi. Các nút export cũ trong Coaching vẫn là report/audit log theo format cũ; dùng **Soạn report ngày** cho báo cáo công việc gửi quản lý.

Chi phí token được lưu cố định khi tạo report, với basis và phiên bản giá. Chi phí chưa biết không được coi là miễn phí. Quota là snapshot tài khoản/provider dùng chung được thu trong ngày; không lấy quota hôm nay để điền ngày hôm qua. Một số nguồn không có trên máy hoặc đang ghi dở sẽ được ghi rõ trong phạm vi dữ liệu.

## Gợi ý từ coding agent

Phần tùy chọn cho phép sao chép prompt cùng bằng chứng đã lọc, chủ động đưa vào coding agent, rồi dán JSON gợi ý trở lại AgentWatch. Schema chỉ cho phép summary và gợi ý cho các đầu việc/bằng chứng đã tồn tại. Model không được sửa ngày, metrics, trạng thái, địa chỉ nhận, quyền gửi hay xác nhận của nhân viên. Gợi ý bị từ chối không thay đổi bản nháp. Người dùng có thể tiếp tục với template xác định mà không cần model.

## Storage và khả năng kiểm tra

Snapshot nội bộ được lưu ngoài repo trong `~/Library/Application Support/AgentWatch/reports/`, quyền thư mục 0700 và file 0600. Ghi file atomic, đồng bộ xuống đĩa và khóa liên tiến trình khi cấp revision. Snapshot có schema đóng, dấu hash của nội dung và thông tin chốt; đọc lại phải kiểm tra schema/hash. Không đổi bảng giá hay quét lại log để tính lại bản cũ.

Schema có thể kiểm tra tại `Sources/AgentWatchCore/Resources/daily-report-v1.schema.json`; kiểm tra tham chiếu, trạng thái, kỳ và tổng số nằm trong `ReportValidator`. Nhật ký nguồn/hash là bằng chứng về dữ liệu đã thu, không phải chữ ký xác thực kết quả nghiệp vụ.

Google Drive/Gmail là các phase tiếp theo. Chưa có thao tác đăng nhập tài khoản công ty, upload hay gửi email nào được thực hiện trong quá trình kiểm tra này.
## Bổ sung prompt/task và app theo ngày

Report có bảng rà soát từng prompt dùng cho task nào, đánh giá phạm vi dự án kèm lý do, và tổng hợp coding app/agent đã sử dụng trong ngày. Xem [quy tắc dữ liệu và hướng dẫn rà soát](report-daily-activity.md). Report cũ cần tạo lại bản nháp để thu các mục mới.
