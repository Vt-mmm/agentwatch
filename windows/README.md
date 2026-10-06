# Agent Watch cho Windows

Agent Watch giữ key Studio của bạn trên máy (mã hoá bằng DPAPI cho tài khoản Windows của bạn) và cấp quyền chạy cho Piagent ở chế độ công ty. Trên Windows, chế độ công ty của Piagent chạy trong **WSL2** (Ubuntu) với sandbox Linux (bubblewrap); Agent Watch là một app Windows, Piagent trong WSL gọi nó qua `agentwatch.exe`.

Bản này có: kết nối Studio bằng mã kết nối, broker cho Piagent, credential helper, kết nối Piagent trong WSL. Báo cáo, coaching và pet của bản macOS chưa có.

## Cài đặt (một lần)

1. **WSL2 với Ubuntu** — mở PowerShell rồi chạy, khởi động lại máy nếu được hỏi:

   ```powershell
   wsl --install -d Ubuntu
   ```

2. **Piagent trong Ubuntu** — mở Ubuntu (Start → Ubuntu) rồi chạy:

   ```bash
   sudo apt-get update && sudo apt-get install -y bubblewrap git ripgrep fd-find build-essential curl
   curl -fsSL https://raw.githubusercontent.com/nvm-sh/nvm/v0.40.3/install.sh | bash && . ~/.nvm/nvm.sh && nvm install 24
   npm install -g --ignore-scripts @piagent/platform
   piagent-update
   piagent --help
   ```

   `piagent --help` chạy một lần để Piagent ghi lại vị trí cài đặt cho Agent Watch.

3. **Agent Watch** — trong PowerShell:

   ```powershell
   irm https://raw.githubusercontent.com/Vt-mmm/agentwatch/main/windows/install.ps1 | iex
   ```

   Agent Watch được cài cho riêng bạn vào `%LOCALAPPDATA%\AgentWatch\app` và có trong Start menu. Bản phát hành chưa ký số: nếu Windows SmartScreen cảnh báo, chọn *More info → Run anyway*.

4. **Kết nối** — trong Agent Watch, dán mã kết nối admin gửi cho bạn, bấm **Kết nối**, rồi bấm **Kết nối Piagent trong WSL**.

5. **Dùng Piagent** — trong Ubuntu:

   ```bash
   piagent dashboard
   ```

   Dashboard mở trong trình duyệt Windows. Để project trong ổ của WSL (ví dụ `~/projects`) cho nhanh; folder Windows (`/mnt/c/...`) vẫn dùng được nhưng chậm hơn.

Chạy lại lệnh ở bước 3 để cập nhật Agent Watch. Sau mỗi lần cập nhật, Agent Watch tự kết nối lại Piagent trong WSL khi mở.

## Chế độ cá nhân

Piagent dùng tài khoản AI của riêng bạn cũng chạy trong Ubuntu (bước 2 và 5 ở trên), không cần Agent Watch. Chạy thẳng trên Windows mới là bản xem trước: xem [Piagent trên Windows](https://github.com/Vt-mmm/piagent/blob/main/docs/vi/windows.md).

## Dòng lệnh

`agentwatch.exe` (cùng thư mục với app) có các lệnh:

| Lệnh | Việc |
|---|---|
| `agentwatch connect "<mã kết nối>"` | Kết nối Studio |
| `agentwatch status` | Các kết nối đã lưu |
| `agentwatch bind-wsl [--distro Ubuntu]` | Cho Piagent trong WSL dùng key công ty |
| `agentwatch disconnect` | Ngắt kết nối, xoá key khỏi máy |

`managed-broker`, `managed-authorize` và `credential` do Piagent và các CLI gọi, không dùng trực tiếp.

## Phát triển

```bash
dotnet test windows/AgentWatch.Windows.sln
```

Core và CLI build và test được trên macOS/Linux (`AGENTWATCH_DATA_DIR` thay DPAPI khi test); app WPF build được ở mọi nơi nhưng chỉ chạy trên Windows. Bản phát hành: tag `windows-vX.Y.Z` trên `main`, workflow `windows` build bản x64 và arm64 rồi tạo GitHub Release.
