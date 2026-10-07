# AgentWatch 0.15.1 (macOS) · 0.1.6 (Windows)

- **Bản mới được báo bằng dialog.** Trước đây Agent Watch trên Mac tải bản mới ngầm và chỉ cài khi thoát app; vì Watch gần như không bao giờ thoát, Sparkle chỉ nhắc sau 1 tuần. Nay khi bản mới tải xong, Watch hỏi ngay: **Cập nhật ngay** (đóng và mở lại trong vài giây) hoặc **Để sau** (nhắc lại sau 1 giờ, vẫn tự cài khi thoát app). Watch vẫn kiểm tra bản mới mỗi giờ.
- **Windows: kiểm tra bản mới mỗi giờ.** Agent Watch cho Windows kiểm tra 30 giây sau khi mở và sau đó mỗi giờ. Có bản mới thì hiện dialog; chọn Yes sẽ chạy đúng lệnh cài đặt PowerShell trong một cửa sổ hiện rõ tiến trình, đóng Agent Watch và các phiên Piagent công ty, cài bản mới rồi mở lại. Chọn No thì 1 giờ sau nhắc lại.

Lưu ý cho lần cập nhật này: dialog có từ 0.15.1 / 0.1.6. Máy đang ở 0.15.0 nhận bản này theo cách cũ, tức là khi thoát Agent Watch hoặc bấm **Check for Updates…**. Máy Windows đang ở 0.1.5 cập nhật bằng lệnh một dòng như trước.

Tải `AgentWatchMac-0.15.1.zip` cho macOS 14 trở lên (Apple Silicon và Intel). `SHA256SUMS` và `release.json` xác định chính xác các file và source được phát hành. App được ký bằng chứng chỉ cố định "Agent Watch Signing", nên quyền Keychain đã cho vẫn giữ qua lần cập nhật.

Bản Windows (x64 và arm64) phát hành qua tag `windows-v0.1.6`.

Kiểm tra trước phát hành:
- `swift test` và build app macOS (Swift 6).
- Windows: build solution, 35 test lõi (thêm test đọc phiên bản từ nguồn phát hành); CI Windows chạy test bộ cài và smoke wizard.
