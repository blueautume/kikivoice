import Foundation
import Security

protocol OpsSocialPendingVault: AnyObject {
    func loadSocialPending(accountID: String) throws -> OpsSocialPendingAction?
    func saveSocialPending(_ value: OpsSocialPendingAction) throws
    func removeSocialPending(accountID: String) throws
}

protocol SessionVault: AnyObject {
    func load() throws -> OpsSession?
    func save(_ session: OpsSession) throws
    func remove() throws
    func purgeLegacySessions() throws
    func loadPendingModeration(accountID: String) throws -> OpsPendingModeration?
    func savePendingModeration(_ value: OpsPendingModeration) throws
    func removePendingModeration(accountID: String) throws
}

extension KeychainSessionVault: OpsSocialPendingVault {
    func loadSocialPending(accountID: String) throws -> OpsSocialPendingAction? {
        var lookup = query(account: "pending-social-moderation." + accountID)
        lookup[kSecReturnData as String] = true; lookup[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: CFTypeRef?
        let status = SecItemCopyMatching(lookup as CFDictionary, &result)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess, let data = result as? Data,
              let value = try? JSONDecoder().decode(OpsSocialPendingAction.self, from: data), value.accountID == accountID else { throw OpsError.keychain(status) }
        try value.request.validate(); return value
    }
    func saveSocialPending(_ value: OpsSocialPendingAction) throws {
        try value.request.validate()
        let lookup = query(account: "pending-social-moderation." + value.accountID)
        let attributes: [String: Any] = [kSecValueData as String: try JSONEncoder().encode(value),
            kSecAttrAccessible as String: kSecAttrAccessibleWhenUnlockedThisDeviceOnly, kSecAttrSynchronizable as String: false]
        let status = SecItemUpdate(lookup as CFDictionary, attributes as CFDictionary)
        if status == errSecItemNotFound {
            var entry = lookup; attributes.forEach { entry[$0.key] = $0.value }
            let inserted = SecItemAdd(entry as CFDictionary, nil)
            guard inserted == errSecSuccess else { throw OpsError.keychain(inserted) }
        } else if status != errSecSuccess { throw OpsError.keychain(status) }
    }
    func removeSocialPending(accountID: String) throws { try delete(query(account: "pending-social-moderation." + accountID)) }
}

final class KeychainSessionVault: SessionVault {
    private let namespace: String
    init(namespace: String = "") { self.namespace = namespace }
    private func query(service: String = OpsIdentityEndpoint.keychainService, account: String = "operations-session") -> [String: Any] {
        [kSecClass as String: kSecClassGenericPassword,
         kSecAttrService as String: service + namespace, kSecAttrAccount as String: account]
    }
    func load() throws -> OpsSession? {
        var query = query(); query[kSecReturnData as String] = true; query[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess, let data = result as? Data else { throw OpsError.keychain(status) }
        guard let session = try? JSONDecoder().decode(OpsSession.self, from: data), session.isValid() else {
            try remove(); return nil
        }
        return session
    }
    func save(_ session: OpsSession) throws {
        guard session.isValid() else { throw OpsError.expired }
        let data = try JSONEncoder().encode(session)
        let lookup = query()
        let attributes: [String: Any] = [kSecValueData as String: data,
            kSecAttrAccessible as String: kSecAttrAccessibleWhenUnlockedThisDeviceOnly,
            kSecAttrSynchronizable as String: false]
        let status = SecItemUpdate(lookup as CFDictionary, attributes as CFDictionary)
        if status == errSecItemNotFound {
            var entry = lookup; attributes.forEach { entry[$0.key] = $0.value }
            let insert = SecItemAdd(entry as CFDictionary, nil)
            guard insert == errSecSuccess else { throw OpsError.keychain(insert) }
        } else if status != errSecSuccess { throw OpsError.keychain(status) }
    }
    func remove() throws { try delete(query()) }
    func loadPendingModeration(accountID: String) throws -> OpsPendingModeration? {
        var lookup = query(account: "pending-moderation." + accountID)
        lookup[kSecReturnData as String] = true; lookup[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: CFTypeRef?
        let status = SecItemCopyMatching(lookup as CFDictionary, &result)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess, let data = result as? Data,
              let value = try? JSONDecoder().decode(OpsPendingModeration.self, from: data),
              value.accountID == accountID else { throw OpsError.keychain(status) }
        try value.request.validate()
        return value
    }
    func savePendingModeration(_ value: OpsPendingModeration) throws {
        try value.request.validate()
        let lookup = query(account: "pending-moderation." + value.accountID)
        let attributes: [String: Any] = [kSecValueData as String: try JSONEncoder().encode(value),
            kSecAttrAccessible as String: kSecAttrAccessibleWhenUnlockedThisDeviceOnly,
            kSecAttrSynchronizable as String: false]
        let status = SecItemUpdate(lookup as CFDictionary, attributes as CFDictionary)
        if status == errSecItemNotFound {
            var entry = lookup; attributes.forEach { entry[$0.key] = $0.value }
            let inserted = SecItemAdd(entry as CFDictionary, nil)
            guard inserted == errSecSuccess else { throw OpsError.keychain(inserted) }
        } else if status != errSecSuccess { throw OpsError.keychain(status) }
    }
    func removePendingModeration(accountID: String) throws {
        try delete(query(account: "pending-moderation." + accountID))
    }
    func purgeLegacySessions() throws {
        // Delete old password-era items by exact namespace without reading them.
        for source in ["voice", "account"] {
            try delete(query(service: "com.kikitalk.voiceops.admin.\(source).v1", account: "admin-session"))
        }
    }
    private func delete(_ query: [String: Any]) throws {
        let status = SecItemDelete(query as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else { throw OpsError.keychain(status) }
    }
}
