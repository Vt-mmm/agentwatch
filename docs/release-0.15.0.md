# AgentWatch 0.15.0 (macOS) · 0.1.5 (Windows)

- **Lý do thật khi Studio từ chối.** Trước đây mọi lần Studio từ chối với mã 409 đều hiện thành "Configuration changed", kể cả khi subagent không có tài khoản AI nào phục vụ. Broker nay chuyển nguyên mã lỗi của Studio (`studio_code`) cho Piagent. Piagent 1.15.0 dùng mã này để nói đúng nguyên nhân, ví dụ "không có tài khoản AI cho model của vai trò này".
- **Tên máy trong log của Studio.** Mỗi lần xin quyền cho main agent hoặc subagent, Agent Watch gửi kèm tên máy (header `X-Agent-Watch-Machine`). Studio 0.19.0 ghi lại để quản trị viên biết máy nào của thành viên gặp lỗi. Không gửi prompt, đường dẫn hay key.
- **Windows: thiết lập từng bước.** Agent Watch cho Windows có wizard 4 bước: chọn cài mới hoặc dùng lại key đã lưu, kiểm tra key, kiểm tra WSL2 và Piagent, rồi xem lại và áp dụng. `setup.ps1` cho chọn cài đầy đủ hoặc chỉ cập nhật app, và chọn bản Ubuntu có sẵn. Bộ cài kiểm tra cả hai file chạy trước khi thay, giữ bản cũ nếu tải lỗi và khôi phục nếu bị ngắt giữa chừng.

Tải `AgentWatchMac-0.15.0.zip` cho macOS 14 trở lên, hỗ trợ Apple Silicon và Intel. Bản CLI độc lập nằm trong asset `agentwatch`. `SHA256SUMS` và `release.json` xác định chính xác các file và source được phát hành. App đang dùng Sparkle có thể chọn **Check for Updates…**. App được ký bằng chứng chỉ cố định "Agent Watch Signing", nên quyền Keychain đã cho vẫn giữ qua lần cập nhật.

Bản Windows (x64 và arm64) phát hành qua tag `windows-v0.1.5`; cài hoặc cập nhật bằng lệnh PowerShell một dòng như trước.

Kiểm tra trước phát hành:
- `swift test`: 342 test, 0 lỗi, 2 test được bỏ qua có chủ đích.
- CI Windows: build, test lõi, test bộ cài và smoke wizard.
- Studio 0.19.0: test tích hợp ghi lại tên máy và mã lỗi của mỗi lần từ chối.
