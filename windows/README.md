# Agent Watch cho Windows

Agent Watch giữ key Studio của bạn trên máy (mã hoá bằng DPAPI cho tài khoản Windows của bạn) và cấp quyền chạy cho Piagent ở chế độ công ty. Trên Windows, chế độ công ty của Piagent chạy trong **WSL2** (Ubuntu) với sandbox Linux (bubblewrap); Agent Watch là một app Windows, Piagent trong WSL gọi nó qua `agentwatch.exe`.

Bản này có: kết nối Studio bằng mã kết nối, broker cho Piagent, credential helper, kết nối Piagent trong WSL. Báo cáo, coaching và pet của bản macOS chưa có.

## Cài đặt: một lệnh

Mở **PowerShell** (Start → gõ PowerShell) và chạy:

```powershell
irm https://raw.githubusercontent.com/Vt-mmm/agentwatch/main/windows/setup.ps1 | iex
```

Chọn **1** để cài đầy đủ hoặc **2** để chỉ cập nhật Agent Watch. Với lựa chọn 1, lệnh lần lượt:

1. Cài WSL2 nếu máy chưa có. Windows hỏi quyền quản trị; lần đầu cần khởi động lại, và cài đặt tự chạy tiếp khi đăng nhập lại.
2. Cài Ubuntu, tạo user Ubuntu theo tên Windows của bạn và hỏi mật khẩu cho user đó (dùng khi chạy `sudo`).
3. Cài Piagent trong Ubuntu: gói hệ thống, sandbox bubblewrap, Node 24, Piagent và đúng bản Pi Piagent đang dùng.
4. Cài Agent Watch và mở wizard: Bắt đầu → nhập mã kết nối hoặc địa chỉ + key riêng → chọn và kiểm tra WSL → xem lại và **Áp dụng**. Key được che khi nhập; chỉ lưu sau khi áp dụng.
5. Thêm mục **Piagent** vào Start menu và hỏi có mở dashboard ngay không.

**Cập nhật:** chạy lại đúng lệnh trên. Những bước đã xong được bỏ qua; Piagent và Agent Watch được cập nhật. Kết nối đã lưu được giữ lại; wizard cho phép kiểm tra lại và áp dụng cho Ubuntu đã chọn. Khi cập nhật, các phiên công ty đang dùng Agent Watch sẽ dừng; mở lại Piagent sau khi xong.

Agent Watch là bản nội bộ chưa ký số: nếu Windows SmartScreen cảnh báo, chọn *More info → Run anyway*.

### Dùng hằng ngày

Mở **Piagent** từ Start menu: một cửa sổ Ubuntu mở dashboard trong trình duyệt Windows. Giữ cửa sổ đó mở khi đang dùng. Để project trong ổ của Ubuntu (ví dụ `~/projects`) cho nhanh; folder Windows (`/mnt/c/...`) vẫn dùng được nhưng chậm hơn.

### Khi cài bị lỗi

| Dấu hiệu | Cách xử lý |
|---|---|
| Lệnh đòi khởi động lại mãi, hoặc Ubuntu báo `0x80370114` | Windows ghi đã bật *Virtual Machine Platform* nhưng thiếu dịch vụ máy ảo. Kiểm tra `Test-Path C:\Windows\System32\vmcompute.exe`; nếu ra `False`, trong PowerShell *Run as administrator* chạy `DISM /Online /Cleanup-Image /RestoreHealth`, `sfc /scannow`, rồi tắt và bật lại tính năng (mỗi lần Restart): `dism.exe /online /disable-feature /featurename:VirtualMachinePlatform /norestart`, `dism.exe /online /enable-feature /featurename:VirtualMachinePlatform /all /norestart`. Vẫn thiếu: cài đè Windows 11 bằng Installation Assistant, chọn giữ file và ứng dụng. |
| `0x80370102` hoặc lỗi ảo hoá | Bật Virtualization (Intel VT-x / AMD SVM) trong BIOS. |
| Tải Ubuntu lỗi mạng | `wsl --install -d Ubuntu --web-download`, rồi chạy lại lệnh cài. |
| Dashboard báo Agent Watch hoặc Piagent vừa cập nhật | Chạy lại lệnh cài (hoặc trong Agent Watch bấm **Kiểm tra WSL** rồi **Áp dụng**). |

Kiểm tra máy: trong Ubuntu chạy `piagent studio --doctor`. Cài từng bước bằng tay: xem [Piagent trên Windows](https://github.com/Vt-mmm/piagent/blob/main/docs/vi/windows.md).

## Chế độ cá nhân

Piagent dùng tài khoản AI của riêng bạn cũng chạy trong Ubuntu: chạy lệnh cài ở trên; có thể đóng wizard Agent Watch nếu không dùng key công ty. Chạy thẳng trên Windows mới là bản xem trước: xem [Piagent trên Windows](https://github.com/Vt-mmm/piagent/blob/main/docs/vi/windows.md).

## Dòng lệnh

`agentwatch.exe` (cùng thư mục với app) có các lệnh:

| Lệnh | Việc |
|---|---|
| `agentwatch connect "<mã kết nối>"` | Kết nối Studio (`connect -` đọc mã từ đầu vào chuẩn để tránh đưa key vào lịch sử lệnh) |
| `agentwatch status` | Các kết nối đã lưu |
| `agentwatch bind-wsl [--distro Ubuntu]` | Cho Piagent trong WSL dùng key công ty |
| `agentwatch check-wsl [--distro Ubuntu]` | Kiểm tra Piagent trong WSL (user, Node, bản Pi) mà không cần key |
| `agentwatch disconnect` | Ngắt kết nối, xoá key khỏi máy |

Chỉ cài hoặc cập nhật Agent Watch (không đụng tới Ubuntu): `irm https://raw.githubusercontent.com/Vt-mmm/agentwatch/main/windows/install.ps1 | iex`.

`managed-broker`, `managed-authorize` và `credential` do Piagent và các CLI gọi, không dùng trực tiếp.

## Phát triển

```bash
dotnet test windows/AgentWatch.Windows.sln
```

Core và CLI build và test được trên macOS/Linux (`AGENTWATCH_DATA_DIR` thay DPAPI khi test); app WPF build được ở mọi nơi nhưng chỉ chạy trên Windows. Bản phát hành: tag `windows-vX.Y.Z` trên `main`, workflow `windows` build bản x64 và arm64 rồi tạo GitHub Release.
