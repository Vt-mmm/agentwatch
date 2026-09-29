# AgentWatch 0.12.0

- Tab Studio: nhập base URL và member API key, tải model được cấp, chọn Claude Code, Codex, Pi hoặc Piagent rồi áp dụng cấu hình bằng một nút.
- Đồng bộ cấu hình ở nền, khi mạng trở lại và khi máy thức dậy. App tiếp tục chạy khi đóng cửa sổ và đăng ký mở lúc đăng nhập macOS.
- Bỏ key giám sát cũ. Member API key vẫn được bảo vệ trong Keychain; quyền model do Studio quản lý.
- Giao diện Studio gọn hơn; dữ liệu Claude 5.5 và cấu hình Sonnet 5.5 giữ context gốc 1M, output tối đa 128K.
- Giữ chức năng theo dõi usage, báo cáo local và danh tính ứng dụng hiện có.

Tải `AgentWatchMac-0.12.0.zip` cho macOS 14+, hỗ trợ Apple Silicon và Intel. Bản CLI độc lập nằm trong asset `agentwatch`. `SHA256SUMS` và `release.json` xác định chính xác các file và source phát hành.

Ứng dụng đang dùng Sparkle có thể chọn **Check for Updates…**. Gói cập nhật được ký bằng khóa Sparkle hiện hữu. App được ký ad-hoc, chưa Apple notarize; lần cài đầu có thể cần xác nhận mở trong macOS. Quyền Login Items/Keychain vẫn do macOS quyết định.

Kiểm tra trước phát hành: 170 kiểm tra Core liên quan đã qua, hai kiểm tra live được bỏ qua có chủ đích; build Release universal, CLI, chữ ký ứng dụng và chữ ký gói cập nhật. Không gọi inference của provider trong lượt phát hành này.
