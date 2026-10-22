import Foundation
import Security
import XCTest

/// Exercises the simulator's real Keychain entitlement and the same item class /
/// accessibility policy used by production sessions. A disposable service and account
/// ensure this never reads or removes a user's saved credentials.
final class KikiKeychainRuntimeTests: XCTestCase {
    func testSignedSimulatorCanWriteReadUpdateAndDeletePrivateKeychainItem() throws {
        let namespace = UUID().uuidString
        let query: [CFString: Any] = [
            kSecClass: kSecClassGenericPassword,
            kSecAttrService: "com.kikitalk.demo.validation." + namespace,
            kSecAttrAccount: "temporary-session-" + namespace
        ]
        defer { SecItemDelete(query as CFDictionary) }
        let original = Data(UUID().uuidString.utf8)
        let updated = Data(UUID().uuidString.utf8)
        var insert = query
        insert[kSecValueData] = original
        insert[kSecAttrAccessible] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        try requireSuccess(SecItemAdd(insert as CFDictionary, nil), operation: "add")

        var read = query
        read[kSecReturnData] = true
        read[kSecMatchLimit] = kSecMatchLimitOne
        var result: CFTypeRef?
        try requireSuccess(SecItemCopyMatching(read as CFDictionary, &result), operation: "read")
        XCTAssertEqual(result as? Data, original)

        try requireSuccess(SecItemUpdate(query as CFDictionary, [kSecValueData: updated] as CFDictionary), operation: "update")
        result = nil
        try requireSuccess(SecItemCopyMatching(read as CFDictionary, &result), operation: "read updated")
        XCTAssertEqual(result as? Data, updated)

        try requireSuccess(SecItemDelete(query as CFDictionary), operation: "delete")
        result = nil
        XCTAssertEqual(SecItemCopyMatching(read as CFDictionary, &result), errSecItemNotFound)
    }

    private func requireSuccess(_ status: OSStatus, operation: String) throws {
        guard status == errSecSuccess else {
            let detail = SecCopyErrorMessageString(status, nil) as String? ?? "Unknown Keychain error"
            XCTFail("Real Keychain \(operation) failed: \(status) \(detail)")
            throw NSError(domain: NSOSStatusErrorDomain, code: Int(status), userInfo: [NSLocalizedDescriptionKey: detail])
        }
    }
}
