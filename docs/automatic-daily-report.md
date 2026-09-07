# Xuất report ngày tự động

Trong Coaching, chọn ngày rồi bấm **Xuất report ngày**. Không cần đọc Coaching trước, không cần điền hồ sơ, sửa công việc, gắn prompt hoặc tích xác nhận. App tự đọc toàn bộ nguồn log coding agent đã cấu hình trên máy theo ngày và thời điểm chốt, độc lập với bộ lọc agent/dự án/tìm kiếm của Coaching.

PDF lưu trong `~/Documents/AgentWatch Reports/`, tên có ngày và mã riêng để không ghi đè. Sau khi xong, nút **Mở report** mở file. **Chỉnh sửa report…** giữ luồng chỉnh sửa thủ công khi cần.

Họ tên và định danh lấy từ key đã xác thực. Tổ chức dùng cấu hình đã có; nếu chưa có thì hiển thị Chưa cấu hình tổ chức, không chặn xuất và không tự đoán công ty. Report tự động không được đóng dấu nhân viên đã duyệt và không được tự gửi ra Google.

## Nội dung tự tổng hợp

- Coding app/agent trong ngày, phiên/dự án, số prompt, token và chi phí phần có dữ liệu.
- Nhóm công việc theo phiên hoặc task journal của Pi. Tự tìm journal trong các dự án Pi xuất hiện trong log đã quét.
- Nhóm mục đích yêu cầu bằng bộ phân loại quy tắc cục bộ; không gọi model. Tổng quan trích yêu cầu cụ thể; phụ lục xuất toàn bộ nội dung prompt sau khi che mẫu thông tin xác thực phổ biến và lược ngữ cảnh hệ thống nhận diện được. Đây là gợi ý nhóm yêu cầu, không phải bản kết luận nghiệp vụ do AI viết.
- Phạm vi dự án chưa có bằng chứng giữ Chưa xác định. Không suy hoàn thành, test đạt hay triển khai thành công chỉ từ log.
- Quota lấy các snapshot đã lưu thuộc ngày được chọn; không dùng quota hiện tại cho ngày cũ.

## Ứng dụng khác trên máy

Máy cần gắn key lần đầu. Những lần đăng nhập sau, AgentWatch dùng danh tính máy đã gắn để ghi nền ngay khi app chạy, kể cả khi màn hình báo cáo đang chờ nhập key. Quyền xem/xuất vẫn yêu cầu xác thực key cho lượt mở app. Collector ghi tên/bundle ID của ứng dụng phía trước màn hình và khoảng thời gian quan sát. Lưu cục bộ theo key, lấy mẫu khoảng 15 giây và khi đổi ứng dụng; tạm ngừng khi máy sleep hoặc phiên người dùng mất hoạt động. Không đọc tiêu đề cửa sổ, nội dung chat/tài liệu, URL, lịch sử duyệt web hoặc thao tác bàn phím.

Thời gian foreground có thể gồm lúc ứng dụng đang mở nhưng người dùng không thao tác. Từ bản chi tiết, mỗi khoảng được phân loại: có tương tác gần đây (sự kiện nhập liệu trong 60 giây), không thao tác trên 60 giây, hoặc chưa rõ (dữ liệu cũ/khoảng chuyển trạng thái). Lấy thời gian từ CoreGraphics với kCGAnyInputEventType, không đăng ký event tap hay lưu phím gõ. Đây là ước lượng theo mẫu khoảng 15 giây, không chứng minh con người đang làm việc. Không quy đổi thành giờ công hoặc năng suất. Khoảng ngừng app, trước khi gắn key lần đầu, trước khi cài bản này hoặc khi máy sleep không được tự điền. Force quit có thể mất đoạn quan sát cuối chưa lưu. Không có khả năng khôi phục lịch sử Chrome/Slack/VS Code trước khi collector bắt đầu.

Report cắt khoảng quan sát theo múi giờ/ngày/cutoff, loại bản ghi lặp, tránh đếm chồng và tách theo employee ID. Các trường desktop activity là phần tùy chọn, nên snapshot cũ vẫn đọc được. Hệ thống hiện thu khi AgentWatch chạy; đây không phải một dịch vụ giám sát độc lập của hệ điều hành.

## Kiểm tra

Unit tests kiểm tra khoảng qua nửa đêm, cutoff, trùng/chồng khoảng, tách employee, lưu/đọc lịch sử, ngày quá khứ chưa có dữ liệu, xuất tự động không cần xác nhận thủ công, che thông tin xác thực, giữ phần cuối prompt dài và thứ tự thời gian, tương thích snapshot và lưu hai PDF không ghi đè. PDF mẫu được render và kiểm tra bố cục/tiếng Việt.

## Bố cục report chi tiết

1. Tổng quan: tên/ngày, số prompt, phiên, app, thời lượng quan sát; các yêu cầu cụ thể theo dự án. Kết quả, vướng mắc và tiếp theo không có căn cứ thì ghi rõ chưa xác nhận.
2. Ứng dụng: thanh tỷ lệ thời gian foreground; tách tương tác gần đây/không thao tác/chưa rõ, diễn biến theo giờ, mốc đầu/cuối và các khoảng thiếu mẫu. Khoảng thiếu không được tính là idle.
3. Agent: số prompt, phiên, usage, token, chi phí ước tính và quota.
4. Chất lượng dữ liệu/phạm vi chưa xác định.
5. Phụ lục: toàn bộ prompt đã lọc theo giờ, mã P001…, agent, phiên, dự án/task, trạng thái phạm vi; tối đa 3 ghi nhận công cụ và tổng số để đối chiếu. Các công cụ nằm giữa hai prompt cùng phiên chỉ là liên kết theo thời gian; chưa thể suy ra quan hệ nhân quả khi agent xử lý đồng thời. Không xuất private reasoning hoặc toàn bộ phản hồi assistant.

PDF có đầu trang/chân trang, số trang, mục đánh số, ô chỉ số, thanh tỷ lệ và ngắt trang giữ đoạn ngắn. Prompt dài chảy tiếp sang trang sau, không cắt mất nội dung. HTML/JSON/CSV cũng đưa nội dung prompt đã lọc vào phần chi tiết. Snapshot cũ không có trường mới vẫn đọc được.

## Tự mở và ghi cả ngày

Dùng SMAppService.mainApp của Apple đăng ký tự mở khi **đăng nhập tài khoản macOS**. Không thể ghi ứng dụng trước khi đăng nhập hoặc khi máy tắt. Coaching hiển thị trạng thái tự mở và nút **Cài đặt tự mở** tới Mục đăng nhập macOS nếu cần duyệt. Nên chạy app từ vị trí cài ổn định, tránh đường dẫn build tạm. Việc macOS hiển thị “đã bật” không thay thế kiểm thử khởi động lại/đăng nhập thật trên máy triển khai.

Collector khởi động từ applicationDidFinishLaunching, không phụ thuộc mở tab Coaching. Dừng ghi khi sleep/phiên không hoạt động; thức dậy tạo mốc mới, không lấp thời gian ngủ. Đóng cửa sổ vẫn chạy nền. Thoát bình thường flush đoạn cuối; force quit có thể mất mẫu cuối. AgentWatch không là dịch vụ chống can thiệp: người có quyền quản trị máy có thể dừng hoặc sửa dữ liệu cục bộ.

Tham khảo bố cục: https://www.atlassian.com/software/confluence/templates/project-status

Tham khảo tự mở: https://developer.apple.com/documentation/servicemanagement/smappservice/register()

Tham khảo thời gian sự kiện: https://developer.apple.com/documentation/coregraphics/cgeventsource/secondssincelasteventtype(_:eventtype:)

## Phân biệt nhân viên và agent tự chạy

Một số Codex `user_message` chứa `<codex_internal_context>` để tiếp tục goal tự động, hoặc chỉ chứa ngữ cảnh máy/turn. Report nhận diện các dấu này, tách khỏi chỉ số **Prompt nhân viên** và ghi bảng riêng theo giờ. Không suy rằng nhân viên làm việc ban đêm từ các lượt agent tự chạy. Mục tiêu tiếp tục được giữ; boilerplate điều phối lặp lại được lược. Prompt chưa có dấu tự động được giữ là prompt nhân viên theo cấu trúc nguồn, không phải bằng chứng xác minh danh tính người gõ. Các màn Coaching cũ vẫn có thể hiển thị tổng user-message event; số trong report chi tiết đã được tách.

Ghi nhận công cụ chỉ xuất giờ, loại công cụ và có/chưa có phản hồi. Mã lệnh, đầu ra công cụ và private reasoning không nằm trong bản quản lý; nội dung yêu cầu của nhân viên vẫn có đầy đủ sau lọc.
