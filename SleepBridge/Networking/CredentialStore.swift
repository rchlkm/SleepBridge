import Foundation
import Security

/// Minimal Keychain read/write for the three Google OAuth values.
/// These are credentials, so Keychain rather than UserDefaults.
enum CredentialStore {
    private static let service = "com.sleepbridge.googlefit"

    static func save(key: String, value: String) {
        let data = Data(value.utf8)
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: key
        ]
        SecItemDelete(query as CFDictionary) // overwrite if present
        var attributes = query
        attributes[kSecValueData as String] = data
        SecItemAdd(attributes as CFDictionary, nil)
    }

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

    static func hasAllCredentials() -> Bool {
        return read(key: "clientId") != nil
            && read(key: "clientSecret") != nil
            && read(key: "refreshToken") != nil
    }
}
