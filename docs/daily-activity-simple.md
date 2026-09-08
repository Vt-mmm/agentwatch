# Nhật ký ngày tự động và PDF tối giản

Theo yêu cầu ngày 08/09/2026, luồng mặc định chuyển từ đọc thủ công sang chuẩn bị dữ liệu cục bộ tự động.

- Mở app vào **Sessions**, thanh trên cùng có một nút **Xuất báo cáo hôm nay**. Không còn màn hình Trong ngày. Sau khi có danh tính mở app, dữ liệu tất cả nguồn/dự án vẫn được khôi phục và cập nhật nền mỗi 60 giây.
- Bộ nhớ và cache trên đĩa tách theo hồ sơ, nguồn log và ngày. Các yêu cầu trùng ngày đang chạy dùng chung một lần đọc. Ngày quét cố định giúp tái sử dụng bộ đọc log tăng dần; bản báo cáo cắt đúng thời điểm cập nhật. Khi lỗi cập nhật, giữ bản cũ cùng thời điểm của nó và hiện lỗi.
- Một lần bấm tự lấy bản chuẩn bị sẵn, lưu PDF và mở bằng ứng dụng đọc PDF. Nếu dữ liệu thiếu/cũ thì tự cập nhật trước. Không tải toàn bộ lịch sử snapshot lúc dựng nút xuất, không cần nút Mở report thứ hai. Không tự gửi ra nhà cung cấp.
- Coaching và Task/context nằm trong Cài đặt → Nâng cao, chỉ chạy phân tích khi mở. Chi tiết task/context thu gọn và có giải thích dễ hiểu. Coaching tự tải phạm vi được chọn. Tasks tự chọn dự án gần nhất nếu chưa chọn, tự cập nhật mỗi phút. Lịch sử tự tìm sau 250 ms và tự lập chỉ mục khoảng còn thiếu. Liên kết task thủ công là tùy chọn nâng cao, không phải điều kiện xem nhật ký.
- PDF gồm số prompt người dùng, app, thời điểm/nơi gửi, toàn bộ yêu cầu đã lọc và thao tác với đường dẫn file. Không xuất lệnh bash/terminal, phản hồi model, nội dung file hoặc đầu ra công cụ. Lượt agent tự tiếp tục không cộng vào số prompt người dùng.
- File lấy từ tham số Read/Write/Edit và đường dẫn trong apply_patch, không đoán từ văn bản phản hồi hoặc phân tích lệnh shell. Cache metadata file thay đổi theo dấu thời gian/kích thước/inode, kể cả ghi lại cùng độ dài. Liên hệ với prompt chỉ là cùng phiên và khoảng thời gian, không xác nhận thành công; prompt trùng thời điểm không được gán file mơ hồ.
- Ngoài agent, bộ thu thập hiện chỉ biết app foreground và trạng thái có tương tác/nhàn rỗi. Chưa biết file đang mở hoặc nội dung click/gõ trong mọi app; PDF nêu rõ phạm vi này. Không bổ sung keylogger hay đọc nội dung cửa sổ.

## Kiểm tra thủ công ngắn

1. Mở bản mới: không có tab Trong ngày; nút Xuất báo cáo hôm nay ở thanh trên cùng.
2. Bấm xuất đúng một lần: app tự chuẩn bị phần còn thiếu, lưu và mở PDF. Không chọn nguồn, dự án hoặc task.
3. Gửi thêm prompt trong agent đang dùng. Sau một chu kỳ cập nhật, xuất lại và đối chiếu đúng app/dự án/ngày.
4. Cài đặt → Nâng cao → Phân tích task và context: đọc phần giải thích; chi tiết và tùy chỉnh mặc định thu gọn. Quay lại đưa về Sessions.
5. Nếu cần ngày cũ, vào Coaching và lịch sử ở mục Nâng cao, chọn ngày và xuất; đây là luồng phụ.

Kiểm tra tự động dùng nguồn giả lập: loại command/model/file body, giữ đường dẫn qua agent continuation, phát hiện file rewrite, lưu/khôi phục cache, tách danh tính/ngày, schema snapshot và phân trang prompt dài. App Release được build; PDF mẫu được render và kiểm tra trực quan. Kiểm tra tương tác app do người dùng thực hiện theo yêu cầu trước đó.

## Bản bàn giao

- App: `Releases/AgentWatchMac-daily-preview-r3.app`. Build Release thành công, chữ ký bundle được kiểm tra.
- PDF giả lập: `output/pdf/agentwatch-daily-simple.pdf` (1 trang). Prompt dài: `output/pdf/agentwatch-long-prompt.pdf` (4 trang).
- Bộ test cuối: 210 bài, 0 lỗi, 1 bỏ qua (đọc log thật cần bật riêng). Không commit/push hoặc tự gửi báo cáo.

Bản giao diện thu gọn thay thế luồng Trong ngày: không đổi nội dung PDF hay parser. Kiểm tra hồi quy SimpleDailyActivityTests và build Release được thực hiện; tương tác giao diện vẫn do người dùng kiểm tra.

### Khôi phục nút gửi Google

Thanh chính có hai nút cạnh nhau: **Xuất báo cáo hôm nay** và **Gửi Google**. Cả hai dùng cùng dữ liệu đã chuẩn bị. Nút Gửi Google mở lại luồng xem bản báo cáo và gửi qua Drive/Gmail hiện có; không cần xuất PDF trước, không tự tải lịch sử báo cáo khi mở app. Bổ sung giao diện không thực hiện gửi dữ liệu thử tới nhà cung cấp.
