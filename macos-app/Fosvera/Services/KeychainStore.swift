import Foundation
import LocalAuthentication
import Security

/// Minimal Keychain wrapper for the one secret this app stores: the user's
/// Gemini API key. A generic-password item keyed by service + account, so the
/// key survives relaunches without ever being written to a plaintext file.
enum KeychainStore {
    private struct KeychainItem {
        let service: String
        let account: String
    }

    // Preserve this established service so existing tester keys remain usable
    // across the Fosvera rebrand.
    private static let currentItem = KeychainItem(
        service: "com.semanticfilefinder.app.gemini-api-key",
        account: "gemini-api-key"
    )

    // Builds shipped before the signed-release work used this item. Keep a
    // non-interactive compatibility path so existing testers are not forced to
    // paste a key again, while never reviving the repeated Keychain prompt.
    private static let legacyItem = KeychainItem(
        service: "com.semanticfilefinder.gemini-api-key",
        account: "gemini"
    )

    /// The stored API key, or nil when none has been saved yet.
    ///
    /// Reads are non-interactive by default so SwiftUI refreshes and helper
    /// startup checks do not create repeated macOS Keychain password prompts.
    static func readAPIKey(allowPrompt: Bool = false) -> String? {
        if let key = readAPIKey(from: currentItem, allowPrompt: allowPrompt) {
            return key
        }

        // Migrate a readable development key once. If Keychain denies the
        // migration without UI, still return the legacy key for this launch;
        // users can save it again later without losing access immediately.
        guard let legacyKey = readAPIKey(from: legacyItem, allowPrompt: allowPrompt) else {
            return nil
        }
        if saveCurrentAPIKey(legacyKey, allowPrompt: allowPrompt) {
            _ = deleteAPIKey(for: legacyItem, allowPrompt: allowPrompt)
        }
        return legacyKey
    }

    private static func readAPIKey(from item: KeychainItem, allowPrompt: Bool) -> String? {
        var query = baseQuery(for: item, allowPrompt: allowPrompt)
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var matchedItem: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &matchedItem)
        guard status == errSecSuccess,
              let data = matchedItem as? Data,
              let key = String(data: data, encoding: .utf8),
              !key.isEmpty
        else { return nil }
        return key
    }

    /// True when the current app can see a saved key without showing Keychain UI.
    static func hasAPIKey() -> Bool {
        hasAPIKey(for: currentItem) || hasAPIKey(for: legacyItem)
    }

    private static func hasAPIKey(for item: KeychainItem) -> Bool {
        var query = baseQuery(for: item, allowPrompt: false)
        query[kSecReturnAttributes as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var matchedItem: CFTypeRef?
        return SecItemCopyMatching(query as CFDictionary, &matchedItem) == errSecSuccess
    }

    @discardableResult
    static func saveAPIKey(_ key: String) -> Bool {
        guard saveCurrentAPIKey(key, allowPrompt: false) else { return false }
        // A newly saved release key supersedes any readable legacy item.
        _ = deleteAPIKey(for: legacyItem, allowPrompt: false)
        return true
    }

    private static func saveCurrentAPIKey(_ key: String, allowPrompt: Bool) -> Bool {
        let data = Data(key.utf8)
        // Update in place if the item exists; add it otherwise.
        let update: [String: Any] = [
            kSecValueData as String: data,
            kSecAttrLabel as String: "Fosvera Gemini API Key",
        ]
        var status = SecItemUpdate(
            baseQuery(for: currentItem, allowPrompt: allowPrompt) as CFDictionary,
            update as CFDictionary
        )
        if status == errSecItemNotFound {
            var query = baseQuery(for: currentItem, allowPrompt: allowPrompt)
            query[kSecValueData as String] = data
            query[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
            query[kSecAttrLabel as String] = "Fosvera Gemini API Key"
            status = SecItemAdd(query as CFDictionary, nil)
        }
        return status == errSecSuccess
    }

    @discardableResult
    static func deleteAPIKey() -> Bool {
        let currentDeleted = deleteAPIKey(for: currentItem, allowPrompt: false)
        let legacyDeleted = deleteAPIKey(for: legacyItem, allowPrompt: false)
        return currentDeleted && legacyDeleted
    }

    private static func deleteAPIKey(for item: KeychainItem, allowPrompt: Bool) -> Bool {
        let status = SecItemDelete(baseQuery(for: item, allowPrompt: allowPrompt) as CFDictionary)
        return status == errSecSuccess || status == errSecItemNotFound
    }

    private static func baseQuery(for item: KeychainItem, allowPrompt: Bool) -> [String: Any] {
        var query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: item.service,
            kSecAttrAccount as String: item.account,
        ]
        if !allowPrompt {
            let context = LAContext()
            context.interactionNotAllowed = true
            query[kSecUseAuthenticationContext as String] = context
        }
        return query
    }
}
