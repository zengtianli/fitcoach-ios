import Foundation
import Security

/// 密码只存本机钥匙串，各服务器分别保存，避免切换地址时带出凭证。
enum SavedLogin {
    struct Credentials: Codable, Equatable {
        let email: String
        let password: String
    }
    static func serverKey(_ server: String) -> String {
        server.trimmingCharacters(in: .whitespacesAndNewlines)
            .trimmingCharacters(in: CharacterSet(charactersIn: "/"))
    }
    private static func query(_ server: String) -> [String: Any] {
        [kSecClass as String: kSecClassGenericPassword,
         kSecAttrService as String: "cyou.tianli.fitcoachapp.saved-login",
         kSecAttrAccount as String: serverKey(server)]
    }
    static func load(server: String) throws -> Credentials? {
        var q = query(server)
        q[kSecReturnData as String] = true
        q[kSecMatchLimit as String] = kSecMatchLimitOne
        var value: CFTypeRef?
        let status = SecItemCopyMatching(q as CFDictionary, &value)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess, let data = value as? Data else { throw StoreError(status: status) }
        return try JSONDecoder().decode(Credentials.self, from: data)
    }
    static func save(_ credentials: Credentials, server: String) throws {
        let data = try JSONEncoder().encode(credentials)
        let q = query(server)
        let update = SecItemUpdate(q as CFDictionary, [kSecValueData as String: data] as CFDictionary)
        if update == errSecSuccess { return }
        guard update == errSecItemNotFound else { throw StoreError(status: update) }
        var item = q
        item[kSecValueData as String] = data
        item[kSecAttrAccessible as String] = kSecAttrAccessibleWhenUnlockedThisDeviceOnly
        let status = SecItemAdd(item as CFDictionary, nil)
        guard status == errSecSuccess else { throw StoreError(status: status) }
    }
    static func remove(server: String) throws {
        let status = SecItemDelete(query(server) as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else { throw StoreError(status: status) }
    }
    struct StoreError: LocalizedError {
        let status: OSStatus
        var errorDescription: String? { "无法访问已保存的登录信息，请重试（\(status)）。" }
    }
}
