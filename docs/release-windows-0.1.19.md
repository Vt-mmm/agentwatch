# Agent Watch for Windows 0.1.19

- **Helper advisor và general cho cuộc trò chuyện company.** Broker đọc thêm hai helper advisor và general trong Harness của Agent Studio 0.51.0 và chuyển cho Piagent 1.52.0, mỗi helper một grant riêng. Trước đây Agent Watch bỏ qua hai helper này nên Piagent không thấy chúng. Studio hay Piagent cũ thì không đổi gì.

Bản Windows (x64 và arm64) phát hành qua tag `windows-v0.1.19`. Bản macOS mang cùng thay đổi là 0.15.20.

Kiểm tra trước phát hành: `AgentWatch.Core.Tests` (58 test); CI Windows trên commit được gắn tag.
