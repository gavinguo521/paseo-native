import Foundation
import Security

enum AppBuild {
    static var isDevelopment: Bool { Bundle.main.object(forInfoDictionaryKey: "PaseoDevBuild") as? Bool == true }

    /// DEV starts with a copy, then keeps its preferences and logical client identity independent.
    static func prepareDevelopmentPreferences() {
        guard isDevelopment, !AppDefaults.store.bool(forKey: "dev.preferencesSeeded"),
              let source = Bundle.main.object(forInfoDictionaryKey: "PaseoDevSeedBundleID") as? String else { return }
        let defaults = AppDefaults.store
        let values = defaults.persistentDomain(forName: source) ?? [:]
        for (key, value) in values where key != "clientId" && key != "localDaemon.previousCLILink" && !key.hasPrefix("updates.") {
            defaults.set(value, forKey: key)
        }
        defaults.set(false, forKey: "menuBarExtra")
        defaults.set(true, forKey: "dev.preferencesSeeded")
    }
}

/// Pairing links are keys to a machine and passwords are secrets: both live only in the Keychain.
enum Keychain {
    private static let productionService = "com.gavin.paseo.hosts"
    private static var service: String { AppBuild.isDevelopment ? productionService + ".dev" : productionService }

    static func load(_ account: String) -> Data? {
        if let data = read(account, service: service) { return data }
        // Seed the normal host list locally once; never seed test accounts or write the production item.
        let marker = "dev.hostsSeeded"
        if AppBuild.isDevelopment, account == "hosts.v1", !AppDefaults.store.bool(forKey: marker),
           let data = read(account, service: productionService) {
            save(data, account: account)
            AppDefaults.store.set(true, forKey: marker)
            return data
        }
        return nil
    }

    private static func read(_ account: String, service: String) -> Data? {
        var query = baseQuery(account)
        query[kSecAttrService as String] = service
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
