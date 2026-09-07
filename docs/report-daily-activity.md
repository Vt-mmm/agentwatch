# Prompt, task, phạm vi dự án và app theo ngày

## Màn hình rà soát

Sau khi tạo bản nháp ngày, mục **App/agent trong ngày** liệt kê coding app có hoạt động từ nguồn log đã đọc. Mục **Prompt → Task → Phạm vi dự án** cho phép đối chiếu từng prompt:

1. Xem thời điểm, app và tên dự án từ log. Prompt gốc chỉ xuất hiện trong phần xem cục bộ sau khi quét, không ghi thêm vào snapshot hoặc bản gửi quản lý.
2. Nhập phần tóm tắt mục đích được phép chia sẻ.
3. Chọn task/đầu việc. Pi có thể được nối sẵn từ task journal; Claude và Codex giữ chưa gắn task khi không có liên kết tường minh.
4. Chọn Trong phạm vi, Ngoài phạm vi hoặc Chưa xác định. Hai kết luận đầu cần task và lý do/yêu cầu dự án để đối chiếu. Kết luận là đánh giá của người rà soát, không phải kết luận tự động của model.

Tên thư mục, tên phiên, số token hay tên dự án trong tên nhân viên không đủ chứng minh nội dung prompt đúng phạm vi. Prompt có thể được gắn đúng task nhưng vẫn ngoài phạm vi; hai thông tin được lưu riêng. Đổi task, đổi tên/dự án của đầu việc hoặc gộp đầu việc sẽ đưa đánh giá phạm vi liên quan về Chưa xác định để rà soát lại.

Chưa xác định là trạng thái hợp lệ và hiện rõ trong report. Không bắt nhân viên chọn một kết luận thiếu căn cứ chỉ để xuất report. Model gợi ý nội dung không được đổi liên kết prompt/task hoặc đánh giá phạm vi.

## Cách tổng hợp

- Lọc prompt theo ngày ở múi giờ của report, khoảng nửa mở và thời điểm chốt; loại bản ghi lặp theo mã prompt có phân biệt nguồn. Không lấy tổng prompt suốt đời session làm số liệu của ngày.
- Nối Pi prompt theo đúng session, đường dẫn dự án và liên kết journal gần nhất không muộn hơn prompt. Nếu có nhiều task tại cùng mốc gần nhất, để chưa gắn; không đoán bằng tiêu đề hay từ khóa.
- Tổng hợp app từ prompt, mốc sự kiện session thuộc ngày và các dòng usage đã được chuẩn hóa của report. App có prompt nhưng chưa có usage vẫn xuất hiện; app chỉ có usage cũng xuất hiện.
- Dùng bảng tra mã usage để phân bổ token cho app, tránh quét lại toàn bộ ledger cho từng dòng. Nếu không phân biệt được nguồn CLI/Desktop, giữ nhóm chưa xác định; không tính token hai lần.
- Đếm session riêng trong từng app. Tổng token và số dòng usage của các nhóm app phải khớp tổng report. Đây là phần được ghi nhận trong log, không phải toàn bộ mức dùng tài khoản.

Các nguồn hiện có: Claude CLI, Claude Desktop, Codex, PiAgent. Codex hiện chưa phân biệt CLI/Desktop. Chưa thu danh sách ứng dụng toàn máy như Chrome, Slack hoặc thời gian ứng dụng ở foreground. Mốc đầu/cuối trong log không phải thời gian dùng liên tục hay giờ công.

## Xuất và tương thích

PDF, HTML, Markdown và nội dung email có mục tổng hợp app, tổng số prompt chưa gắn/chưa xác định/ngoài phạm vi và chi tiết từng prompt. CSV có thêm các dòng hoạt động; JSON chia sẻ có `dailyApps` và `promptTasks`. Mã session, đường dẫn cục bộ và prompt gốc không nằm trong bản chia sẻ.

Snapshot lưu phần `dailyActivity` tùy chọn trong schema đóng. Bản cũ thiếu trường này vẫn đọc và kiểm tra được dấu nội dung; không tự điền dữ liệu mới vào report cũ. Tạo lại bản nháp khi cần thêm hai mục vào report trước đây.

Kiểm tra: biên ngày/cutoff, prompt lặp, thống kê app không lấy số lượng suốt đời session, app chỉ có usage, phân task theo thời điểm, journal nhập nhằng, thiếu lý do phạm vi, reset phạm vi sau gộp, snapshot cũ/mới và loại prompt gốc khỏi các định dạng chia sẻ. Mẫu PDF giả lập được render để kiểm tra tiếng Việt và bố cục.
