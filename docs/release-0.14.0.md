# AgentWatch 0.14.0

- **Báo cáo quy trình phiên bản 3 cho Piagent 1.10.0.** Báo cáo của mỗi lượt công ty nay có thêm số lần subagent phản biện brief, số lần main agent đã trả lời, và số bất đồng chuyển cho member quyết. Kết quả mới `disputed` nghĩa là còn bất đồng, member cần quyết.
- **Chỉ gửi phiên bản mà Studio nhận.** Broker báo cho Piagent các phiên bản báo cáo (`process-v2`, `process-v3`) mà Studio liệt kê. Studio cũ vẫn nhận phiên bản 2 như trước.
- **Không có chữ nào rời máy.** Báo cáo phiên bản 3 vẫn chỉ gồm các con số, cờ và trạng thái đã biết. Báo cáo có giá trị dạng chữ (đoạn prompt, finding, đường dẫn) bị từ chối trước khi gửi.

Tải `AgentWatchMac-0.14.0.zip` cho macOS 14 trở lên, hỗ trợ Apple Silicon và Intel. Bản CLI độc lập nằm trong asset `agentwatch`. `SHA256SUMS` và `release.json` xác định chính xác các file và source được phát hành.

Ứng dụng đang dùng Sparkle có thể chọn **Check for Updates…**. Gói cập nhật được ký bằng khóa Sparkle hiện có. App được ký ad-hoc và chưa Apple notarize: lần cài đầu có thể cần xác nhận mở trong macOS, và macOS sẽ hỏi lại quyền Keychain một lần sau khi cập nhật.

Kiểm tra trước phát hành:
- `swift test`: 341 test, 0 lỗi, 2 test được bỏ qua có chủ đích.
- Build Release universal, CLI, chữ ký ứng dụng và chữ ký gói cập nhật.
- Lượt công ty chạy thật qua Agent Studio với Piagent 1.10.0: broker báo `process-v3`, và Studio lưu báo cáo phiên bản 3 (kết quả `disputed`) của một lượt có bất đồng.
