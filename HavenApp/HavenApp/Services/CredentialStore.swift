import Foundation
import Security

/// Keychain credential storage — platform-specific implementation.
/// Android equivalent: AndroidKeyStore / EncryptedSharedPreferences
/// with the same method signatures and semantics.
///
/// All methods are static and thread-safe (Security framework serialises
/// Keychain access internally).
enum CredentialStore {

    private static let service = "com.havenapp.nip49"
    private static let ownerAccount = "owner-key-password"

    private static func accountId(forNpub npub: String) -> String {
        "account-key-password-\(npub)"
    }

    // MARK: - Owner (global) credential

    @discardableResult
    static func storeOwnerPassword(_ password: String) -> Bool {
        store(password, account: ownerAccount)
    }

    static func getOwnerPassword() -> String? {
        get(account: ownerAccount)
    }

    @discardableResult
    static func deleteOwnerPassword() -> Bool {
        delete(account: ownerAccount)
    }

    static func hasOwnerPassword() -> Bool {
        getOwnerPassword() != nil
    }

    // MARK: - Per-account credentials

    @discardableResult
    static func storePassword(_ password: String, forNpub npub: String) -> Bool {
        store(password, account: accountId(forNpub: npub))
    }

    static func getPassword(forNpub npub: String) -> String? {
        get(account: accountId(forNpub: npub))
    }

    @discardableResult
    static func deletePassword(forNpub npub: String) -> Bool {
        delete(account: accountId(forNpub: npub))
    }

    // MARK: - FIPS mesh network identity

    // Deliberately separate from any Nostr key: the mesh address should be
    // rotatable without touching the social identity. Stored here rather than
    // in HavenConfig because it is a secret, and because the file it would
    // otherwise land in is synced and backed up.
    private static let meshNsecAccount = "fips-mesh-nsec"

    @discardableResult
    static func storeMeshNsec(_ nsec: String) -> Bool {
        store(nsec, account: meshNsecAccount)
    }

    static func getMeshNsec() -> String? {
        get(account: meshNsecAccount)
    }

    @discardableResult
    static func deleteMeshNsec() -> Bool {
        delete(account: meshNsecAccount)
    }

    // MARK: - Private helpers

    private static func store(_ password: String, account: String) -> Bool {
        guard let data = password.data(using: .utf8) else { return false }

        let deleteQuery: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
        SecItemDelete(deleteQuery as CFDictionary)

        let addQuery: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecValueData as String: data,
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlock,
        ]
        return SecItemAdd(addQuery as CFDictionary, nil) == errSecSuccess
    }

    private static func get(account: String) -> String? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var result: AnyObject?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        if status == errSecSuccess, let data = result as? Data {
            return String(data: data, encoding: .utf8)
        }
        return nil
    }

    private static func delete(account: String) -> Bool {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
        let status = SecItemDelete(query as CFDictionary)
        return status == errSecSuccess || status == errSecItemNotFound
    }
}
