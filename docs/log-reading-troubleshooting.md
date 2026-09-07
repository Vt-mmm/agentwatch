# Đọc log lớn và quota Codex

Sửa ngày 07/09/2026 sau khi kiểm tra trên máy có khoảng 28 GB Codex JSONL.

- Bộ đọc JSONL cũ tìm newline lại từ đầu phần dòng đang tích lũy sau mỗi chunk. Với dòng dài chứa ảnh/tool output, số byte bị tìm lặp tăng theo bình phương độ dài dòng. Bộ đọc mới tìm từng byte mới bằng `memchr`, giữ nguyên dòng qua ranh giới chunk, UTF-8 và dòng cuối không có newline; hỗ trợ dừng khi task bị hủy.
- Codex dùng bộ phân tích ISO 8601 dạng giá trị cho timestamp thông thường, giữ đường tương thích cho timestamp cũ. Biên thời gian và số liệu vẫn được kiểm tra theo khoảng nửa mở.
- Coaching có tiến độ số file và nút Dừng đọc. Task đã hủy không ghi cache một file đọc dở hoặc ghi đè kết quả của lượt mới. Kỳ đã đọc chỉ được đánh dấu sau khi có kết quả; định danh kỳ dựa vào khoảng ngày thay vì giờ/giây lúc mở tab.
- Sessions hiện “Đang đọc log Codex…” trong khi đọc, tránh hiển thị “no log” gây hiểu nhầm. Không bỏ log cũ chỉ dựa trên mtime vì log được sao chép có thể giữ mtime cũ.
- Làm mới Codex tự tìm executable trong ChatGPT/Codex app và vị trí cài CLI phổ biến. Có thể chọn vị trí khác; lựa chọn được nhớ cho lần sau. Không đọc hoặc xuất nội dung auth.json. Chỉ gọi phương thức đọc quota, không gọi model hoặc mua/reset quota.

Quota tài khoản và lịch sử session là hai nguồn khác nhau. Quota cần Làm mới Codex; Coaching cần Đọc log theo ngày được chọn. Lịch sử lớn vẫn cần thời gian quét lần đầu. Quota của thời điểm hiện tại không được điền vào report ngày cũ.

Giao thức quota: [tài liệu OpenAI App Server](https://learn.chatgpt.com/docs/app-server).

## Kết quả kiểm tra trên máy

Bộ kiểm tra thường: 122 tests đạt, build Debug macOS thành công. Kiểm tra thật ngày 07/09/2026 quét 1.570 file, nhận được 2 session Codex và 51 prompt ở thời điểm đọc; số prompt tiếp tục thay đổi khi có hoạt động mới. Lượt quét với bộ đọc tuyến tính mất khoảng 202 giây; sau khi tối ưu timestamp, lượt kiểm tra tiếp theo mất khoảng 75 giây. Đây là số đo trên máy với bộ log hiện tại, không phải cam kết thời gian cho mọi máy.

Quota đã đọc thành công qua executable đi kèm ứng dụng ChatGPT, trả về 3 cửa sổ quota. Đã kiểm tra màn hình quota trên AgentWatch hiển thị snapshot thật và thao tác Làm mới Codex không cần mở hộp chọn executable. Không đăng nhập thay người dùng, không đọc mã key, không gửi report ra ngoài.

Kiểm tra UI bản cuối sau khi người dùng nhập key: Coaching hoàn tất 1.570 file và hiển thị 2 session, 52 prompt (snapshot lúc 08:51 ngày 07/09/2026). Chuyển sang Sessions rồi quay lại Coaching giữ nguyên snapshot, không quay về trạng thái chưa đọc. Sessions hiển thị quota thật đã lưu; trong lúc đang quét recent Codex, nhãn thể hiện trạng thái đang đọc thay vì no log.
