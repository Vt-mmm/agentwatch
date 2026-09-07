# Gửi report qua Google

Luồng hiện tại dùng tài khoản Google riêng của nhân viên trên ứng dụng macOS. Sau **Xuất report ngày**, chọn **Gửi report…**, xem PDF và xác nhận nội dung để tạo phiên bản bất biến. Luồng chỉnh sửa thủ công vẫn dùng **Xuất / gửi**. Có thể upload Drive, gửi Gmail hoặc tiếp tục từ Drive sang Gmail. Hai kênh có xác nhận và trạng thái riêng.

## Cấu hình Google Console

1. Tạo/chọn project thuộc công ty; bật Google Drive API, Gmail API và Google Picker API.
2. Cấu hình Google Auth Platform: tên ứng dụng, thông tin liên hệ và audience phù hợp. Internal chỉ phù hợp tổ chức Workspace hỗ trợ; External dùng cho tài khoản ngoài tổ chức. Thêm test users khi đang thử nghiệm.
3. Tạo OAuth client loại **Desktop app**. Trong Settings → **Kết nối Google cho report…**, nhập file JSON Desktop bằng nút **Nhập file cấu hình Google**; secret được chuyển vào Keychain, không đưa token hoặc file cấu hình có secret vào Git.
4. Đăng nhập qua trình duyệt hệ thống. Ứng dụng dùng PKCE/state và callback IPv4 loopback `127.0.0.1` với cổng ngẫu nhiên. Không dùng WebView đăng nhập.
5. Kiểm tra đúng địa chỉ tài khoản hiển thị trước khi chọn đích. Access/refresh token và client secret được lưu trong Keychain; thông tin hiển thị công khai lưu trong preferences.

Các scope: `openid email`, `drive.file`; khi chọn Gmail thêm `gmail.send`. Không đọc inbox, không tạo Gmail draft, không dùng service account/admin key. Google hiện không hỗ trợ incremental authorization cho installed apps: khi bật Gmail, đăng nhập lại với toàn bộ bộ quyền được chọn, rồi kiểm tra quyền và identity trả về.

`drive.file` là non-sensitive; `gmail.send` là sensitive. Quy trình verification tùy audience và cách phát hành. Quản trị viên Workspace có thể chặn ứng dụng dù người dùng đã đồng ý. Chức năng **Ngắt kết nối trên máy** xóa credential local, không tuyên bố đã thu hồi grant ở Google; muốn thu hồi toàn bộ cần vào phần quản lý kết nối tài khoản Google.

## Drive

### Một key — một tên — một thư mục mặc định

Key mở app hiện có là nguồn nhận diện; không phải Google credential. Sau khi xác thực key, tên nhãn của key tự trở thành tên hồ sơ và tên thư mục đề xuất. Mã nhân viên được dẫn xuất ổn định để đổi tên nhãn không làm đổi liên kết; không lưu raw key/hash đăng nhập trong binding.

Ở lần đầu, nhân viên chọn trực tiếp folder riêng đã được quản trị viên chia sẻ qua **Chọn thư mục của tôi…**. Nếu đã cấp quyền cho app, có thể dùng link/ID ở phần nâng cao. Không cần chọn, cấp quyền hay đọc folder tổng. App không tạo folder mới trong luồng nhân viên.

Binding được lưu theo tổ chức + mã nhân viên từ key + tài khoản Google. Lần sau app tự điền folder ID, không dùng lại thư mục của một tài khoản khác. Đích được kiểm tra ở cả UI và dịch vụ upload (gồm lịch gửi). Không ghi đè binding sang folder khác hay gắn cùng folder cho key khác trên cùng máy. Đổi tên folder trên Google vẫn giữ liên kết theo ID; không tự tìm theo tên vì Drive cho phép tên trùng.

Công ty tạo sẵn folder riêng cho từng nhân viên; app gắn trực tiếp folder đó. Chính sách nhóm vẫn cần cho phép mã nhân viên/account/folder tương ứng. Tên folder đại diện có thể khác tên nhãn nếu folder có sẵn được quản trị đổi tên; ID mới là đích thật. Chuyển binding sang folder khác cần quy trình quản trị, hiện UI không cho tự đổi.

Binding là dữ liệu local; khi chuyển máy cần cấp lại cấu hình/gắn folder đã có. Cơ chế này không phải server cấp license hoặc bảo đảm một key chỉ hoạt động trên đúng một thiết bị. Quyền OAuth và quyền Drive vẫn phải được cấp riêng. Có Google Picker trong trình duyệt hệ thống để cấp quyền với thư mục hiện có.

Trong phần kết nối, nhân viên nhập JSON Desktop do quản trị viên gửi, đăng nhập Gmail cá nhân, chọn folder riêng bằng Google Picker và điền email sếp. Không bắt buộc dán link trước; ô nhập link/ID nằm trong cấu hình nâng cao. Bấm một lần lên thẻ folder rồi bấm **Chèn / Insert**; bấm đúp chỉ mở bên trong folder. Nếu đã nhập ID để đối chiếu, app yêu cầu chọn đúng folder đó. App kiểm tra tài khoản, quyền thêm file, quyền hiện có của chính folder, chính sách nhóm nếu có và liên kết với key. App không đọc hoặc đòi quyền folder cha. Biết ID không tự cấp quyền `drive.file`; app không tự tăng scope toàn Drive.

Để các nhân viên không xem report của nhau, quản trị viên giữ folder tổng cho quản trị/sếp và chia sẻ từng folder con trực tiếp với đúng Gmail nhân viên bằng quyền Editor. Giữ quyền truy cập chung ở Restricted; rà soát các quyền nhóm hoặc quyền kế thừa đã cấp rộng từ trước. Picker cấp quyền cho ứng dụng, còn quyền chia sẻ Drive quyết định người nào xem được dữ liệu. Việc bỏ chọn folder cha trong AgentWatch không tự thu hồi quyền Google đã cấp trước đó. Cấu hình cũ vẫn giữ folder đã gắn; các preference folder tổng cũ không còn được dùng trong giao diện nhân viên.

Luồng này vẫn dùng app local và tài khoản Google riêng trên từng máy. Quản trị viên thêm 20 Gmail vào Test users và gửi file JSON; quyền Testing với các scope hiện tại hết hạn sau 7 ngày nên nhân viên cần đăng nhập lại khi app báo hết quyền. Không phải nhập lại JSON hoặc gắn lại folder đã lưu nếu vẫn dùng cùng key/tài khoản. Nếu người dùng thu hồi quyền truy cập folder của app, cần cấp lại đúng folder đó bằng Picker; việc đăng nhập lại không tự thay thế grant folder.

Màn xem trước hiển thị PDF cùng quyền hiện có của thư mục. Nhân viên duyệt đúng tài khoản, thư mục, quyền và nội dung; quyền được kiểm tra lại ngay trước upload. Upload không tự thêm người nhận hoặc mở public. File có thể kế thừa quyền thư mục.

Adapter hỗ trợ PDF nhị phân tối đa 5 MB, dùng multipart, không chuyển thành Google Docs. File ID được cấp và lưu trước upload. Khi mất mạng, thao tác phục hồi đối chiếu cùng ID, metadata và hash bytes, tránh tạo một file mới. Receipt gồm ID và link chuẩn của file đã xác minh. Có receipt không chứng minh người nhận mở được file; nghiệm thu thực phải kiểm tra bằng tài khoản người nhận.

## Gmail

Nhập email không kèm tên hiển thị, phân cách bằng dấu phẩy. To/Cc/Bcc được hiển thị rõ trước khi gửi; địa chỉ sai, trùng hoặc chứa ký tự chèn header bị từ chối. From là mailbox đã xác minh qua OAuth, không hỗ trợ tùy ý đổi alias.

Email có plain text, HTML tiếng Việt và PDF đính kèm. PDF là lựa chọn mặc định hiện tại, độc lập quyền Drive; không tự chèn link Drive rồi giả định sếp có quyền xem. Nút tiếp tục từ Drive mở bước Gmail riêng, không upload lại Drive nếu Gmail lỗi.

Ứng dụng lưu nguyên MIME, PDF và Message-ID trước khi gửi. Xác nhận ràng buộc employee, phiên bản report, người nhận/tiêu đề và hash nội dung. Đổi cấu hình phải xem trước và duyệt lại. Hai lần bấm hay worker đồng thời không cùng gửi một job. Hộp thư đi được lưu bền ngoài repository.

| Trạng thái | Ý nghĩa và cách xử lý |
|---|---|
| Chờ duyệt gửi | Chưa có yêu cầu Gmail; cần xem và xác nhận |
| Đang gửi yêu cầu | Đã lưu intent trước network; không khởi động worker gửi thứ hai |
| Gmail đã nhận yêu cầu | Có message ID trả về; không chứng minh delivery hoặc đã đọc |
| Yêu cầu bị từ chối | Lỗi xác thực/quyền/request/quota rõ ràng; sửa nguyên nhân, xem lại và thử sau thời gian backoff |
| Chưa rõ đã gửi | Timeout, lỗi máy chủ, response thiếu receipt hoặc ứng dụng dừng giữa chừng; không tự gửi lại |
| Người dùng xác nhận trong Sent | Ghi nhận đối chiếu thủ công, không bịa Gmail receipt |

Với kết quả chưa rõ: mở Gmail đúng tài khoản, tìm `rfc822msgid:<mã hiển thị>` trong Sent và kiểm tra cả người nhận/nội dung. Nếu đã thấy thì xác nhận đã thấy. Nếu chưa thấy, chỉ mở lại quyền chuẩn bị gửi khi đã ghi chú kiểm tra và chấp nhận nguy cơ gửi trùng; vẫn cần duyệt gửi lại. Message-ID hỗ trợ tra cứu, không phải idempotency guarantee của Gmail. Không thấy kết quả tìm kiếm ngay cũng không chứng minh chưa gửi.

Mọi timeout hoặc lỗi không phân loại chắc đều giữ trạng thái cần đối chiếu. Không có vòng tự retry send. Quota dùng backoff có jitter và lưu thời điểm thử lại. OAuth/token refresh thực hiện trước gửi; không tự refresh rồi resend một yêu cầu đang chưa rõ kết quả.

## Kiểm thử và nghiệm thu

Test transport giả lập đã bao phủ PKCE/identity/scope, fixed Drive IDs, quyền thư mục thay đổi, hash file, quota backoff, MIME tiếng Việt, các người nhận, timeout/5xx, crash lease, duplicate worker, approval/account/payload mismatch và đối chiếu thủ công. MIME còn được parse bằng thư viện email độc lập để kiểm tra cấu trúc, Unicode và PDF.

Ngày 2026-09-07: đã nhập JSON Desktop qua app vào Keychain và xác thực thành công tài khoản thử với Drive/Gmail trên Google thật. Bộ kiểm tra gồm 134 test, một test đọc dữ liệu thật chỉ chạy opt-in. Picker đã chạy thành công với folder tổng: callback có ID, đổi code, đối chiếu tài khoản, kiểm tra quyền bằng token Picker và credential chính. Folder nhân viên có sẵn cần grant riêng khi API trả 404; chọn folder tổng không được coi là đã cấp quyền cho mọi folder con. Đã chọn và cấp quyền riêng folder nhân viên, xác minh folder nằm trong folder tổng và lưu binding thành công vào kho local. Sau khi người dùng duyệt rõ bản report ngày 07/09/2026 chốt 10:35:36 (20 trang), đã upload thành công và Gmail trả message ID accepted. Hàng đợi local lưu receipt của cả hai kênh. Vì công cụ điều khiển cửa sổ bị ngắt kết nối ở màn PDF, lần gửi nghiệm thu dùng trực tiếp cùng DriveDeliveryService/GmailDeliveryService, credential Keychain và outbox của app qua harness riêng trong thư mục tạm. Không bypass kiểm tra snapshot/hash, binding, policy, approval, lease hoặc trạng thái không rõ. Chưa kiểm tra inbox bên nhận hoặc toàn bộ thao tác nút gửi qua UI; accepted không chứng minh người nhận đã đọc. PDF/MIME đã được parse độc lập, đúng một người nhận, không Cc/Bcc, một PDF 20 trang; không còn mẫu secret Google/enrollment key đã kiểm tra. Nghiệm thu live cần: đăng nhập/refresh/cancel; mở PDF Drive bằng người nhận; gửi một email được duyệt đến địa chỉ thử; kiểm tra Sent và inbox thực; kiểm tra quyền khi tài khoản đổi/ngắt kết nối. Không dùng report nhân viên thật cho bài thử đầu tiên.

## Picker trên macOS

Picker dùng cùng Desktop client, PKCE/state và callback loopback, chỉ xin `drive.file` với `prompt=consent`, `trigger_onepick=true`, lọc folder và chọn một thư mục. Luồng này tách khỏi đăng nhập Gmail vì Google không cho kết hợp scope khác trong Picker. Mã callback luôn được đổi lấy token mới; app đối chiếu email qua Drive `about`, kiểm tra quyền thư mục bằng token mới rồi bằng credential chính. Token Picker chỉ giữ tạm, không ghi đè refresh token có quyền Gmail. Chọn khác tài khoản hoặc callback có nhiều ID bị từ chối.

Email nhận mặc định và link thư mục lưu trên máy; không hardcode cấu hình công ty trong mã nguồn. Dữ liệu xác thực không được ghi vào report; mẫu `GOCSPX-` được che cả trong prompt tiếng Việt.

## Nguồn chính thức, kiểm tra 2026-09-07

- [Desktop OAuth, PKCE và loopback](https://developers.google.com/identity/protocols/oauth2/native-app).
- [Drive scopes](https://developers.google.com/workspace/drive/api/guides/api-specific-auth), [upload và pre-generated IDs](https://developers.google.com/workspace/drive/api/guides/manage-uploads).
- [Gmail MIME/send](https://developers.google.com/workspace/gmail/api/guides/sending), [scope classifications](https://developers.google.com/workspace/gmail/api/auth/scopes), [lỗi và giới hạn delivery](https://developers.google.com/workspace/gmail/api/guides/handle-errors).

- [Google Picker cho desktop/mobile](https://developers.google.com/workspace/drive/picker/guides/desktop-mobile-picker), [Drive about.get](https://developers.google.com/workspace/drive/api/reference/rest/v3/about/get).

## Sửa luồng UI ngày 2026-09-07

Luồng tự động dùng một sheet có dữ liệu cụ thể và chuyển bước ngay trong sheet: xem report → **Tiếp tục với Drive/Gmail** → chuẩn bị tự động bằng cấu hình đã lưu → duyệt đích và **Upload/Gửi bản đã duyệt**. Không xếp thêm hai sheet Drive/Gmail lên sheet xem PDF. Thanh trạng thái/lỗi nằm trên vùng cuộn; thành công có thông báo xanh và receipt/link. PDFView chỉ nạp lại tài liệu khi bytes thay đổi, giữ trang đang xem khi tick checkbox.

**Report đã chốt** mở lại các phiên bản đã lưu theo ngày và key, giữ revision cũ để khôi phục đúng outbox; không quét log hoặc tạo revision mới khi chỉ xem lịch sử. Giao diện kết nối hiển thị tài khoản, folder và email đã lưu. JSON, client ID và ô dán link nằm trong phần nâng cao; Picker không yêu cầu nhập ID trước trên máy chưa gắn folder. Cấu hình vẫn lưu riêng theo máy; bản này chưa tự phân phối OAuth config/folder binding từ máy quản trị sang tất cả máy nhân viên.

Kiểm tra bản cài mới: build thành công; người dùng xác nhận màn Google hiển thị tài khoản, thư mục và cấu hình nâng cao. Qua UI đã mở lại đúng revision 2 chốt 10:48:34 (21 trang) từ lịch sử và bấm tiếp tục với Drive; kho Drive ghi nhận revision 2 ở trạng thái `prepared`, chưa upload. Công cụ điều khiển macOS bị crash khi đọc cửa sổ phụ (`SkyComputerUseService`, `Array.remove(at:)`), nên cần đối chiếu phần hiển thị tiếp theo với người dùng. Đây chưa phải bằng chứng gửi thành công revision 2 qua UI; receipt của revision 1 thuộc lần kiểm tra dịch vụ trước đó.


## Folder riêng, không yêu cầu folder tổng — cập nhật 2026-09-07

Màn kết nối chỉ còn tài khoản, folder nhân viên và email nhận. Màn upload dùng cùng dịch vụ gắn folder đã chọn, không có nút chọn folder công ty hoặc tạo folder theo tên key. Không truy vấn parents khi xác minh folder riêng; mã tạo folder phục vụ trường hợp quản trị trong core vẫn giữ kiểm tra parent nhưng không nằm trong UI nhân viên. Binding cũ và policy giới hạn folder/account vẫn được giữ.

Test hồi quy kiểm tra: gắn và đọc lại folder con khi metadata không có parents, chỉ gọi GET trên folder con và ACL của nó; từ chối folder không có quyền thêm file; từ chối folder ngoài chính sách trước khi gọi Google. Kiểm thử giả lập này không thay thế nghiệm thu quyền thực bằng Gmail nhân viên chỉ được chia sẻ folder con.

Kết quả: 34 kiểm tra thuộc ReportEnrollmentTests, GoogleSetupTests, GoogleDeliveryTests và ReportTeamTests đạt; bản macOS build thành công và đã cài tại `~/Applications/AgentWatch.app`. Không đổi quyền chia sẻ Drive, không thu hồi grant cũ và không gửi thêm report trong lượt cập nhật này. UI bổ sung nút cấp lại quyền đúng folder đã lưu trong phần nâng cao, dành cho trường hợp grant folder bị thu hồi; nút này không cho đổi sang folder khác.

Người dùng đã xác nhận trên app: màn kết nối chỉ còn tài khoản, nơi nhận và folder riêng; không còn ô/nút chọn folder tổng. Nghiệm thu trên các Gmail nhân viên khác sẽ thực hiện với release 0.10.0.
