import Foundation
import Security

/// API key storage in the macOS Keychain (generic password, service `li.rol.dev.stackd`).
enum KeychainStore {
    private static let service = "li.rol.dev.stackd"
    private static let account = "api-key"
    /// Service of the app's former name (boxd-bar); migrated once in `loadAPIKey()`.
    private static let legacyService = "sh.boxd.bar"
    /// Only the real app bundle may touch the Keychain. In any other process (`swift test` runs in
    /// `swiftpm-testing-helper`, CI, a bare binary) every call is a no-op, so no test can read,
    /// overwrite or delete the user's real key — an early test run once deleted it.
    static let isDisabled = Bundle.main.bundleIdentifier != "li.rol.dev.stackd"

    private static var query: [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
    }

    private static func read(_ q: [String: Any]) -> String? {
        var q = q
        q[kSecReturnData as String] = true
        q[kSecMatchLimit as String] = kSecMatchLimitOne
        var item: CFTypeRef?
        guard SecItemCopyMatching(q as CFDictionary, &item) == errSecSuccess,
              let data = item as? Data else { return nil }
        return String(decoding: data, as: UTF8.self)
    }

    static func loadAPIKey() -> String? {
        guard !isDisabled else { return nil }
        if let key = read(query) { return key }
        // One-time migration from the legacy boxd-bar service (may trigger one Keychain prompt).
        let legacy: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: legacyService,
            kSecAttrAccount as String: account,
        ]
        guard let key = read(legacy) else { return nil }
        if saveAPIKey(key) { SecItemDelete(legacy as CFDictionary) }
        return key
    }

    @discardableResult
    static func saveAPIKey(_ key: String) -> Bool {
        guard !isDisabled else { return false }
        SecItemDelete(query as CFDictionary)
        var q = query
        q[kSecValueData as String] = Data(key.utf8)
        q[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlock
        return SecItemAdd(q as CFDictionary, nil) == errSecSuccess
    }

    static func deleteAPIKey() {
        guard !isDisabled else { return }
        SecItemDelete(query as CFDictionary)
    }
}
