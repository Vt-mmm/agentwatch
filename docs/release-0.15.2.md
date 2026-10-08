# AgentWatch 0.15.2 (macOS)

- **Báo rõ khi cần cấp quyền Keychain.** Sau khi Agent Watch cập nhật, macOS có thể cần bạn cho phép đọc lại key Studio. Trước đây việc đồng bộ nền chỉ lặng lẽ báo lỗi bên trong app: cấu hình Piagent vẫn mang chữ ký bản Watch cũ, nên chế độ công ty của Piagent (Terminal `piagent studio` và dashboard) báo `managed-launch-binding-changed` cho tới khi bạn tự mở Watch và bấm "Cho phép Keychain". Nay Watch tự hiện dialog "Agent Watch cần quyền đọc key công ty" với nút **Cho phép ngay**; cho phép xong Watch đồng bộ ngay để Piagent dùng được tiếp. "Để sau" sẽ được nhắc lại sau 1 giờ.
- Lần cập nhật 0.15.1 → 0.15.2 dùng dialog "Có bản Agent Watch mới · Cập nhật ngay / Để sau" của 0.15.1.

Tải `AgentWatchMac-0.15.2.zip` cho macOS 14 trở lên (Apple Silicon và Intel). `SHA256SUMS` và `release.json` xác định chính xác các file và source được phát hành. App được ký bằng chứng chỉ cố định "Agent Watch Signing".

Bản Windows vẫn là `windows-v0.1.6`.

Kiểm tra trước phát hành:
- `swift test`: 343 test, 0 lỗi, 2 test được bỏ qua có chủ đích (thêm test: đồng bộ nền báo cần quyền Keychain, cho phép xong thì đồng bộ ngay).
- Build app macOS (Swift 6).
