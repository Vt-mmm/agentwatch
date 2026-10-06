namespace AgentWatch;

// The same failure codes as the macOS app (StudioClient.swift): the managed
// broker sends them to Piagent as `managed-broker:<code>`.
public enum StudioError
{
    invalidOrigin, invalidKey, incompatibleVersion, invalidResponse, redirectDenied,
    permissionDenied, quotaExceeded, rateLimited, serverUnavailable, upstreamUnavailable, offline,
    storage, keychainApprovalRequired, identityChanged, disconnectFirst,
}

public sealed class StudioException(StudioError code) : Exception(code.ToString())
{
    public StudioError Code { get; } = code;

    public static string Describe(StudioError code) => code switch
    {
        StudioError.invalidOrigin => "Nhập địa chỉ gốc của API Studio, không kèm đường dẫn hoặc key. Cần HTTPS; HTTP chỉ dùng với 127.0.0.1 hoặc [::1] để thử local.",
        StudioError.invalidKey => "Key không hợp lệ, hết hạn hoặc đã bị thu hồi. Kiểm tra lại key nhân viên.",
        StudioError.incompatibleVersion => "Phiên bản API Studio chưa tương thích với Agent Watch này.",
        StudioError.invalidResponse => "Studio trả về dữ liệu không hợp lệ. Chưa thể xác nhận kết nối.",
        StudioError.redirectDenied => "Địa chỉ này chuyển hướng. Nhập trực tiếp API origin của Studio; key không được gửi theo chuyển hướng.",
        StudioError.permissionDenied => "Key chưa có quyền truy cập phần dữ liệu này.",
        StudioError.quotaExceeded => "Hạn mức Studio đã hết.",
        StudioError.rateLimited => "Studio đang giới hạn lượt gọi. Thử lại sau.",
        StudioError.serverUnavailable => "Studio hiện chưa sẵn sàng. Thử kiểm tra lại sau.",
        StudioError.upstreamUnavailable => "Nhà cung cấp AI hiện chưa sẵn sàng.",
        StudioError.offline => "Chưa kết nối được Studio.",
        StudioError.storage => "Không đọc hoặc lưu được key trên máy này. Thử lại.",
        StudioError.keychainApprovalRequired => "Chưa đọc được key Studio đã lưu. Mở Agent Watch và kết nối lại.",
        StudioError.identityChanged => "Danh tính server trả về đã thay đổi. Ngắt kết nối và kiểm tra lại tài khoản trước khi kết nối lại.",
        StudioError.disconnectFirst => "Ngắt kết nối hiện tại trước khi chuyển sang Studio hoặc tài khoản khác.",
        _ => code.ToString(),
    };
}
