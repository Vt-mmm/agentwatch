# AgentWatch 0.11.0

- Tự chuẩn bị dữ liệu báo cáo ngày ở nền; cache SQLite và bộ đọc JSONL tăng dần giúp giảm việc đọc lại lịch sử.
- Hai nút cạnh nhau trên màn hình chính: **Xuất báo cáo hôm nay** và **Gửi Google**. Xuất PDF tự lưu và mở; gửi Google dùng dữ liệu đã chuẩn bị để mở luồng Drive/Gmail.
- PDF tập trung vào prompt người dùng, thời điểm, app/dự án/phiên và file đã thao tác. Loại lệnh terminal/bash, phản hồi model, nội dung file và lượt tự tiếp tục của agent khỏi phần nhật ký người dùng.
- Giao diện thu gọn; Coaching và phân tích task/context nằm trong **Nâng cao**. Bổ sung lịch sử tìm kiếm, liên kết task/run, phân tích context và thao tác lặp, bằng chứng kết quả, sức khỏe nguồn dữ liệu và inbox báo cáo nhóm cục bộ.

Dữ liệu cập nhật theo chu kỳ, không phải thời gian thực. File/thao tác chỉ phản ánh nguồn log được hỗ trợ; app ngoài agent chỉ có thời gian foreground và trạng thái tương tác. Không tự gửi dữ liệu tới Google hoặc xác nhận hoàn thành công việc từ lời model.

Kiểm tra: bộ Core tests, build Release macOS, bản CLI và chữ ký gói cập nhật Sparkle. Các thao tác gửi nhà cung cấp không được thực hiện như một phần kiểm thử phát hành.
