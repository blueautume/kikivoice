import Foundation
import Security

protocol KikiIdentityStoring {
    func read(_ key: String) -> String?
    func write(_ value: String, key: String) throws
    func remove(_ key: String)
}

struct KikiKeychainStorage: KikiIdentityStoring {
    func read(_ key: String) -> String? { KikiKeychain.read(key) }
    func write(_ value: String, key: String) throws { try KikiKeychain.write(value, key: key) }
    func remove(_ key: String) { KikiKeychain.remove(key) }
}

enum KikiKeychain {
    private static let service = "com.kikitalk.identity"

    static func read(_ key: String) -> String? {
        let query: [CFString: Any] = [kSecClass: kSecClassGenericPassword, kSecAttrService: service,
                                   kSecAttrAccount: key, kSecReturnData: true, kSecMatchLimit: kSecMatchLimitOne]
        var result: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess,
              let data = result as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }

    static func write(_ value: String, key: String) throws {
        let query: [CFString: Any] = [kSecClass: kSecClassGenericPassword, kSecAttrService: service, kSecAttrAccount: key]
        let attributes: [CFString: Any] = [kSecValueData: Data(value.utf8), kSecAttrAccessible: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly]
        let status = SecItemUpdate(query as CFDictionary, attributes as CFDictionary)
        if status == errSecItemNotFound {
            var insert = query
            attributes.forEach { insert[$0.key] = $0.value }
            guard SecItemAdd(insert as CFDictionary, nil) == errSecSuccess else {
                throw KikiAPIError.security("无法安全保存登录凭据，请重新启动 App 后重试。")
            }
        } else if status != errSecSuccess {
            throw KikiAPIError.security("无法安全保存登录凭据，请重新启动 App 后重试。")
        }
    }

    static func remove(_ key: String) {
        SecItemDelete([kSecClass: kSecClassGenericPassword, kSecAttrService: service, kSecAttrAccount: key] as CFDictionary)
    }

}
