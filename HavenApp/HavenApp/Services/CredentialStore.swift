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

    /// These passwords decrypt the private keys, so they stay on this device:
    /// without `ThisDeviceOnly` an encrypted backup restores them onto another
    /// phone. The mesh identity (FipsMeshService) is stored the same way.
    private static let accessible = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly

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

    /// Moves passwords saved before 3.0.0 (41) onto `ThisDeviceOnly`, in
    /// place, so nobody has to sign in again. Runs at every launch: it only
    /// touches items still on the old class, and before the first unlock it
    /// fails and tries again next time.
    @discardableResult
    static func migrateToThisDeviceOnly() -> OSStatus {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlock,
        ]
        let update: [String: Any] = [kSecAttrAccessible as String: accessible]
        return SecItemUpdate(query as CFDictionary, update as CFDictionary)
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
            kSecAttrAccessible as String: accessible,
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

    /// Every password this store holds, owner and per-account. Factory reset
    /// calls it: the keys they unlock are gone, so the passwords must go too.
    @discardableResult
    static func deleteAll() -> Bool {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
        ]
        let status = SecItemDelete(query as CFDictionary)
        return status == errSecSuccess || status == errSecItemNotFound
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
