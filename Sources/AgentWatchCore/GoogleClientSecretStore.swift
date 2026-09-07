import Foundation
import Security

public enum GoogleClientSecretStore {
    private static func query(_ clientID: String) -> [String: Any] {
        [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: "com.vtamm.agentwatch.google-client",
         kSecAttrAccount as String: ReportEncoding.digest(Data(clientID.utf8))]
    }
    public static func save(_ secret: String, clientID: String) throws {
        let query = query(clientID), data = Data(secret.utf8)
        let status = SecItemUpdate(query as CFDictionary, [kSecValueData as String: data] as CFDictionary)
        if status == errSecItemNotFound {
            var item = query; item[kSecValueData as String] = data
            item[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
            guard SecItemAdd(item as CFDictionary, nil) == errSecSuccess else { throw GoogleServiceError.storage("Không lưu được cấu hình client trong Keychain.") }
        } else if status != errSecSuccess { throw GoogleServiceError.storage("Không cập nhật được cấu hình client trong Keychain.") }
    }
    public static func load(clientID: String) throws -> String? {
        var query = query(clientID); query[kSecReturnData as String] = true; query[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess, let data = result as? Data else { throw GoogleServiceError.storage("Không đọc được cấu hình client từ Keychain.") }
        return String(data: data, encoding: .utf8)
    }
}
