# Tổng hợp báo cáo nhóm cục bộ

Trong tab Tasks, mở **Tổng hợp báo cáo nhóm đã duyệt**. Chức năng dùng mã nhân viên
đã cấu hình cho báo cáo và chính sách nhóm đã cài. Chỉ chủ chính sách còn hiệu lực
được nhập/xem kho tổng hợp. Chức năng này không tạo quyền hoặc tự cài chính sách.

Chọn một thư mục chứa các snapshot JSON đã duyệt rồi bấm nhập. App kiểm tra từng
báo cáo, chỉ nhận đúng tổ chức, thành viên và múi giờ trong chính sách. Nhập lại cùng
bản không tạo bản trùng; phiên bản mới được giữ riêng. Nếu cùng mã/phiên bản nhưng
khác nội dung, app báo xung đột để đối chiếu. Các tệp bị từ chối vẫn giữ nguyên trong
thư mục nguồn. Mỗi lượt xử lý tối đa 500 tệp, mỗi tệp tối đa 16 MiB.

Chọn ngày và đọc tổng hợp để xem bản mới nhất của từng thành viên, công việc chưa
hoàn tất, mục đang vướng và người chưa có báo cáo trong kho. “Chưa có báo cáo” không
có nghĩa là không làm việc. Báo cáo chốt sớm được ghi rõ chưa bao phủ cả ngày.

Trạng thái Gmail/Drive chỉ lấy từ dữ liệu đã lưu trên máy này và phải khớp đúng nội
dung cùng phiên bản báo cáo. App không gọi nhà cung cấp để kiểm tra trạng thái trong
màn hình tổng hợp này. Kho không có biên nhận của máy khác thì hiển thị chưa có dữ liệu.

Đây là kho trên máy của người vận hành, không phải máy chủ phân quyền đa người dùng.
Tên chủ chính sách/hồ sơ cục bộ không thay thế xác thực danh tính. Dấu kiểm nội dung
phát hiện thay đổi tệp, không phải chữ ký số của nhân viên. Màn hình không tự gửi báo
cáo hoặc đồng bộ ra dịch vụ bên ngoài.
