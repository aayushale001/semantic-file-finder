import Foundation
import Security

/// Minimal Keychain wrapper for the one secret this app stores: the user's
/// Gemini API key. A generic-password item keyed by service + account, so the
/// key survives relaunches without ever being written to a plaintext file.
enum KeychainStore {
    private static let service = "com.semanticfilefinder.gemini-api-key"
    private static let account = "gemini"

    /// The stored API key, or nil when none has been saved yet.
    static func readAPIKey() -> String? {
        var query = baseQuery()
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        guard status == errSecSuccess,
              let data = item as? Data,
              let key = String(data: data, encoding: .utf8),
              !key.isEmpty
        else { return nil }
        return key
    }

    @discardableResult
    static func saveAPIKey(_ key: String) -> Bool {
        let data = Data(key.utf8)
        // Update in place if the item exists; add it otherwise.
        let update: [String: Any] = [kSecValueData as String: data]
        var status = SecItemUpdate(baseQuery() as CFDictionary, update as CFDictionary)
        if status == errSecItemNotFound {
            var query = baseQuery()
            query[kSecValueData as String] = data
            status = SecItemAdd(query as CFDictionary, nil)
        }
        return status == errSecSuccess
    }

    @discardableResult
    static func deleteAPIKey() -> Bool {
        let status = SecItemDelete(baseQuery() as CFDictionary)
        return status == errSecSuccess || status == errSecItemNotFound
    }

    private static func baseQuery() -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
    }
}
