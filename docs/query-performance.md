# Truy vấn snapshot nhanh, không realtime

AgentWatch tự chuẩn bị dữ liệu: mở Coaching hoặc đổi kỳ hiển thị snapshot local trước rồi cập nhật nguồn ở nền. Màn hình mặc định Trong ngày tự cập nhật mỗi phút và giữ bản báo cáo để xuất PDF nhanh. Xem [nhật ký ngày tối giản](daily-activity-simple.md).

## Luồng đọc

1. **Mở lại kỳ đã xem:** lấy snapshot từ RAM, hoặc SQLite sau khi khởi động lại. Snapshot giữ thời điểm đọc nguồn cũ; khôi phục không tạo scan audit mới và không cộng XP.
2. **Đọc log, nguồn không đổi:** duyệt danh sách file và đối chiếu fingerprint metadata; dùng lại snapshot cùng các tổng hợp đã tính. Không đọc nội dung JSONL hay chấm prompt lại.
3. **File chỉ nối thêm:** khôi phục trạng thái parser của đúng kỳ và tiếp tục tại byte offset đã lưu. Giữ bộ đếm Codex, dedupe request/prompt, lịch sử tên Pi, lineage/fork và cảnh báo chất lượng.
4. **File thay thế, bị cắt hoặc sửa:** không dùng kết quả cũ. File thay inode, kích thước giảm hoặc sửa cùng kích thước được đọc lại. Khi nối thêm, kiểm tra hash đầu file và vùng trước offset để phát hiện các kiểu ghi lại thông thường.
5. **Kỳ mới:** chỉ mục thời gian giúp bỏ qua file chắc chắn nằm ngoài kỳ. File giao với kỳ chưa được lưu vẫn cần parse lần đầu. Không chia tổng usage cả session cho từng ngày vì sẽ sai khi counter reset hoặc thiếu baseline.
6. **Export:** `forceFullRead` bỏ qua cache và checkpoint; `captureManifest` cũng dùng đường đọc đầy đủ và hash nguồn. Snapshot hiển thị nhanh không thay thế bằng chứng export.

Snapshot chứa tổng hợp chính xác cho kỳ đã chọn, cùng các tổng hợp theo vendor/project/task đã dedupe độc lập. Chọn vendor/project dùng trực tiếp tổng hợp đã tính; lọc thêm model tính trên tập session đã có trong RAM. Danh sách prompt/session tiếp tục phân trang; chi tiết session vẫn chỉ được đọc khi mở.

## Dữ liệu local

- SQLite: `~/Library/Caches/com.vtamm.agentwatch/query-v1.sqlite`, cùng WAL/SHM do SQLite quản lý.
- Cache gồm prompt đã chấm, session summaries, usage ledger, trạng thái parser và metadata file. Không cache raw JSONL, ảnh hoặc nội dung tool result. Nội dung prompt vẫn là dữ liệu riêng tư như trong nguồn.
- File database có quyền `0600`; thư mục mới có quyền `0700`.
- Cache được phân biệt theo root nguồn, kỳ, source, phiên bản parser/accounting/scoring và bảng giá. Khi đổi logic phải tăng `CoachingQueryStore.version`.
- Tối đa 8 snapshot trong RAM; cache file giới hạn 128 entry và khoảng 32 MiB theo ước tính. SQLite dọn khi lưu snapshot: 24 kỳ, 4.000 entry file, dữ liệu quá 30 ngày và tổng payload trên 256 MiB. File vật lý có thể lớn hơn vì SQLite giữ trang trống để tái sử dụng.
- Cache hỏng/không ghi được không chặn đọc nguồn. Checkpoint không decode được sẽ parse lại file. Không xoá hay sửa source log.

## Giới hạn có chủ đích

Checkpoint dừng trước dòng chưa có newline. Dòng cuối được hiển thị nếu parse được nhưng sẽ được đọc lại khi hoàn tất, tránh cộng usage hai lần.

Kiểm tra một số vùng khi append không chứng minh toàn bộ prefix bất biến: ứng dụng sửa giữa file rồi nối thêm, đồng thời giữ nguyên các vùng kiểm tra, có thể vượt qua fast path. Vì vậy export luôn đọc đầy đủ; không dùng cache làm bằng chứng nguyên vẹn của nguồn.

Lần đọc đầu, kỳ chưa lưu có nhiều file giao nhau, file thường xuyên rewrite và snapshot quá lớn có thể vượt mục tiêu 100 ms. Thời gian query không bao gồm vẽ toàn bộ giao diện, risk scoring hoặc export. Chu kỳ tự cập nhật là 60 giây; đây là dữ liệu theo lần chụp, không phải thời gian thực. PDF tối giản dùng bản đã chuẩn bị còn mới; export bằng chứng nâng cao có thể đọc nguồn riêng.

## Kiểm tra và đo

```sh
swift test
swift test -c release --filter CoachingQueryStoreTests
xcodebuild -project AgentWatchMac.xcodeproj -scheme AgentWatchMac -configuration Debug build
```

`CoachingQueryStoreTests` dùng nguồn giả lập và SQLite tạm, đối chiếu kết quả với full parser cho cả ba provider. Có kiểm tra reopen, append, dòng cuối chưa hoàn tất, rewrite/truncate/replacement, scope/root isolation, checkpoint hỏng, cancellation, thứ tự scan và Codex baseline/reset.

Test `testQueryTimingsOnSyntheticHistory` in dòng `QUERY_BENCH`: số file/byte, cold scan, query SQLite sau reopen, query RAM và Refresh không đổi. Các số này là phép đo trên máy chạy test, không phải cam kết độ trễ cho mọi lịch sử thực tế.

### Kết quả đo ngày 08/09/2026

Bản Release trên máy phát triển, fixture 23 file / 6.418.685 byte (~6,4 MB), một lượt đo:

| Thao tác | Thời gian |
|---|---:|
| Đọc/lập snapshot lần đầu | 288,40 ms |
| Query snapshot SQLite sau reopen | 31,88 ms |
| Query snapshot RAM | 0,04 ms |
| Refresh khi nguồn không đổi | 19,78 ms |

Đây là độ trễ tầng dữ liệu trên fixture, chưa phải số đo toàn bộ UI hoặc p95 trên log thực tế. `sourceBytesRead` đếm byte đưa vào parser; các lần đọc nhỏ để kiểm tra hash checkpoint không nằm trong số này.

Kiểm tra hoàn tất: 147 test toàn bộ (1 skipped theo cấu hình có sẵn, 0 failure), 11 test query ở Release (0 failure), và build macOS Debug thành công.

## Local historical event index

The Tasks screen also uses `InsightHistoryStore`, separate from scope snapshots.
Each explicit day refresh indexes prompt text, task timeline metadata and canonical
usage records for the selected project. Queries over newly selected ranges use the
SQLite `(project,time,id)` index and FTS5 without enumerating source logs. Prompt
content remains in the local cache; it is not added to exported reports by this feature.

The index records exactly which time windows were read and when. Missing windows
remain visible as gaps. This implementation does not automatically backfill all
history. The oldest contributing capture time is shown so a quick answer cannot
be mistaken for a fresh source scan. Re-reading a window atomically removes absent
rows, updates the FTS index and replaces its coverage/warnings. A delayed older read
is rejected when it overlaps a newer capture. Invalid writes roll back.

Search accepts literal words (including Vietnamese diacritics), not raw FTS query
syntax. The UI pages 100 matching records; usage totals include all canonical usage
entries in the selected date range, independently of search text and page. They are
observed indexed totals, not an assertion of complete provider billing.

Synthetic Debug sample: 10,000 prompt records, unseen range containing 9,000 records,
90 FTS matches: approximately 1.7 ms in an isolated run and 12 ms while a full app build was running. This isolates local index latency;
it excludes source refresh and is not a guarantee for larger usage ledgers or devices.
