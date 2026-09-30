// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation
import Security
import LocalAuthentication

/// A local, per-user Keychain item; never stored in preferences, scripts or logs.
enum AwayLockPassword {
    struct StorageError: LocalizedError {
        let status: OSStatus
        var errorDescription: String? { "钥匙串操作失败（\(status)），请检查钥匙串访问权限。" }
    }
    private static var query: [String: Any] {
        [kSecClass as String: kSecClassGenericPassword,
         kSecAttrService as String: (Bundle.main.bundleIdentifier ?? "com.vorssaint.utils") + ".away-lock",
         kSecAttrAccount as String: NSUserName(),
         kSecAttrSynchronizable as String: false]
    }
    static func read() throws -> String? {
        var q = query
        q[kSecReturnData as String] = true
        q[kSecMatchLimit as String] = kSecMatchLimitOne
        // Never display a Keychain authorization prompt over the lock screen.
        let context = LAContext()
        context.interactionNotAllowed = true
        q[kSecUseAuthenticationContext as String] = context
        var result: CFTypeRef?
        let status = SecItemCopyMatching(q as CFDictionary, &result)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess, let data = result as? Data,
              let value = String(data: data, encoding: .utf8) else { throw StorageError(status: status) }
        return value
    }
    static func save(_ password: String) throws {
        let attributes: [String: Any] = [kSecValueData as String: Data(password.utf8),
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly]
        var status = SecItemUpdate(query as CFDictionary, attributes as CFDictionary)
        if status == errSecItemNotFound {
            status = SecItemAdd(query.merging(attributes) { _, new in new } as CFDictionary, nil)
        }
        guard status == errSecSuccess else { throw StorageError(status: status) }
    }
    static func delete() throws {
        let status = SecItemDelete(query as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else { throw StorageError(status: status) }
    }
}
