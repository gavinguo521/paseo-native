import Foundation
import Security

/// Pairing links are keys to a machine and passwords are secrets: both live only in the Keychain.
enum Keychain {
    private static let service = "com.gavin.paseo.hosts"

    static func load(_ account: String) -> Data? {
        var query = baseQuery(account)
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var out: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &out) == errSecSuccess else { return nil }
        return out as? Data
    }

    static func save(_ data: Data, account: String) {
        let query = baseQuery(account)
        let attrs: [String: Any] = [
            kSecValueData as String: data,
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly,
        ]
        if SecItemUpdate(query as CFDictionary, attrs as CFDictionary) == errSecItemNotFound {
            SecItemAdd(query.merging(attrs) { $1 } as CFDictionary, nil)
        }
    }

    static func delete(_ account: String) {
        SecItemDelete(baseQuery(account) as CFDictionary)
    }

    private static func baseQuery(_ account: String) -> [String: Any] {
        var q: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
        #if os(iOS)
        q[kSecUseDataProtectionKeychain as String] = true
        #endif
        return q
    }
}
