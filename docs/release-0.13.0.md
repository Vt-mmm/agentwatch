# AgentWatch 0.13.0

- **Chế độ công ty cho Piagent.** Key công ty (managed) được nhập vào Piagent. Agent Watch giữ key trong Keychain và cấp quyền cho từng lượt chạy qua broker, nên Piagent không thấy key.
- **Harness của team đi thẳng từ Studio sang Piagent**, gồm:
  - main agent;
  - các subagent khảo sát, nghiên cứu, xác minh và kiểm tra;
  - quy trình kế hoạch, check và review;
  - mức thinking của từng vai.
- **Model API key của công ty** (DeepSeek, Kimi, GLM, MiMo, Qwen, OpenCode, Grok) dùng được qua Studio.
- **`agentwatch credential` hỏi app đang chạy trước** qua socket riêng (quyền 0600, kiểm tra user), sau đó mới tự đọc Keychain. Claude Code, Codex và Pi vẫn xác thực được sau khi cài bản mới.
- **Tìm được Piagent, Pi và Node trên mọi kiểu cài:** npm prefix riêng, nvm, fnm, asdf, mise, Volta, Homebrew trên Intel. App ghim đúng bản mà lệnh `piagent` đang dùng.
- **Kết nối lại key không còn làm kẹt các thư mục đã cấu hình.** Với key công ty, chỉ chọn được Piagent khi nhập.
- **Báo cáo quy trình phiên bản 2** chỉ được gửi khi Studio nhận phiên bản đó.

Tải `AgentWatchMac-0.13.0.zip` cho macOS 14 trở lên, hỗ trợ Apple Silicon và Intel. Bản CLI độc lập nằm trong asset `agentwatch`. `SHA256SUMS` và `release.json` xác định chính xác các file và source được phát hành.

Ứng dụng đang dùng Sparkle có thể chọn **Check for Updates…**. Gói cập nhật được ký bằng khóa Sparkle hiện có. App được ký ad-hoc và chưa Apple notarize: lần cài đầu có thể cần xác nhận mở trong macOS, và macOS sẽ hỏi lại quyền Keychain một lần sau khi cập nhật.

Kiểm tra trước phát hành:
- `swift test`: 341 test, 0 lỗi, 2 test được bỏ qua có chủ đích.
- Build Release universal, CLI, chữ ký ứng dụng và chữ ký gói cập nhật.
- Một lượt công ty chạy thật qua Agent Studio: subagent khảo sát và xác minh chạy trên model OpenCode Go, review không có lỗi chặn, mọi request đều được tính usage.
