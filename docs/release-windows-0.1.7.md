# Agent Watch for Windows 0.1.7

- **Tải bản cài không còn hỏng giữa chừng.** Trình cài đặt PowerShell tải lại và tải tiếp từ chỗ bị ngắt (`curl.exe --continue-at`, tối đa 5 lần; dùng `Invoke-WebRequest` khi không có curl hoặc TLS lỗi), và dừng lượt tải bị treo thay vì chờ hết một khoảng thời gian cố định.
- **Cập nhật trong app bị lỗi thì vẫn thấy lỗi.** Khi bấm cập nhật từ dialog mà lệnh cài thất bại, cửa sổ PowerShell giữ nguyên để đọc lỗi thay vì tự đóng.

Phần trình cài đặt đã có hiệu lực từ 2026-10-08 (bản cài đọc từ `main`); bản 0.1.7 mang phần thay đổi trong app tới máy đang chạy 0.1.6, qua dialog cập nhật.

Bản Windows (x64 và arm64) phát hành qua tag `windows-v0.1.7`. Không có bản macOS mới.

Kiểm tra trước phát hành: CI Windows (build, test lõi, test bộ cài, smoke wizard) trên commit được gắn tag.
