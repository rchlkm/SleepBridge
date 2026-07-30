import Foundation
import Security

/// Minimal Keychain read/write for the three Google OAuth values.
/// These are credentials, so Keychain rather than UserDefaults.
enum CredentialStore {
    // Groups all three OAuth values under one stable Keychain service name.
    private static let service = "com.sleepbridge.googlefit"

    /// Stores or replaces one OAuth value. Keychain identifies it by service + key.
    static func save(key: String, value: String) {
        let data = Data(value.utf8)
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: key
        ]
        SecItemDelete(query as CFDictionary) // remove a previous value before inserting its replacement
        var attributes = query
        attributes[kSecValueData as String] = data
        SecItemAdd(attributes as CFDictionary, nil)
    }

    /// Returns a saved OAuth value, or nil when the user has not configured it yet.
    static func read(key: String) -> String? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: key,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne
        ]
        var result: AnyObject?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        guard status == errSecSuccess, let data = result as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }

    /// The sync cannot exchange a token until all three OAuth values are present.
    static func hasAllCredentials() -> Bool {
        return read(key: "clientId") != nil
            && read(key: "clientSecret") != nil
            && read(key: "refreshToken") != nil
    }
}
