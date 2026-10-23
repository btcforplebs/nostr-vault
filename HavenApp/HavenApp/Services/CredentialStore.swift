import Foundation
import Security

/// Keychain credential storage — platform-specific implementation.
/// Android equivalent: AndroidKeyStore / EncryptedSharedPreferences
/// with the same method signatures and semantics.
///
/// All methods are static and thread-safe (Security framework serialises
/// Keychain access internally).
enum CredentialStore {

    static let service = "com.havenapp.nip49"
    private static let ownerAccount = "owner-key-password"

    /// These passwords decrypt the private keys, so they stay on this device:
    /// without `ThisDeviceOnly` an encrypted backup restores them onto another
    /// phone. The mesh identity (FipsMeshService) is stored the same way.
    static let accessible = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly as String

    /// The app's own keychain group on iOS. The default group is the first
    /// `keychain-access-groups` entry, `NVSharedStore.accessGroup`, which the
    /// widget carries too and any app on the team's wildcard profile can
    /// claim; this one only the app can read. nil on the Mac, whose login
    /// keychain has no access groups.
    static var privateGroup: String? {
        #if os(iOS)
        return "525WQ48Y72.com.havenapp.relay"
        #else
        return nil
        #endif
    }

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

    // MARK: - Migration

    /// Moves every item into the app's private group on `ThisDeviceOnly`.
    /// Items written before 3.0.0 (41) sit in the shared group on
    /// `AfterFirstUnlock` (#1118 changed their class in place). The copy is
    /// added first and the old item deleted only once the copy is there, so
    /// a failure (before the first unlock, say) leaves the old item readable
    /// and it moves at the next launch. Returns how many items changed.
    @discardableResult
    static func migrateToThisDeviceOnly(in keychain: CredentialKeychain = SystemKeychain(),
                                        privateGroup: String? = privateGroup) -> Int {
        var moved = 0
        for item in keychain.items(service: service)
        where item.group != privateGroup || item.accessible != accessible {
            if let privateGroup, item.group != privateGroup {
                guard let data = keychain.data(service: service, account: item.account, group: item.group) else { continue }
                let status = keychain.add(service: service, account: item.account, data: data,
                                          group: privateGroup, accessible: accessible)
                // A duplicate is a newer value already stored privately.
                guard status == errSecSuccess || status == errSecDuplicateItem else { continue }
                if keychain.delete(service: service, account: item.account, group: item.group) == errSecSuccess {
                    moved += 1
                }
            } else if keychain.updateAccessible(service: service, account: item.account,
                                                group: item.group, to: accessible) == errSecSuccess {
                moved += 1
            }
        }
        return moved
    }

    // MARK: - Any secret, by account name

    @discardableResult
    static func store(_ value: String, account: String,
                      in keychain: CredentialKeychain = SystemKeychain(),
                      privateGroup: String? = privateGroup) -> Bool {
        guard let data = value.data(using: .utf8) else { return false }
        _ = keychain.delete(service: service, account: account, group: nil)
        var status = keychain.add(service: service, account: account, data: data,
                                  group: privateGroup, accessible: accessible)
        if status == errSecMissingEntitlement, privateGroup != nil {
            // A build without the private group entitled: the default group
            // still beats losing the value.
            status = keychain.add(service: service, account: account, data: data,
                                  group: nil, accessible: accessible)
        }
        return status == errSecSuccess
    }

    /// The private group first; any other group only holds an item the
    /// migration has not moved yet.
    static func get(account: String,
                    in keychain: CredentialKeychain = SystemKeychain(),
                    privateGroup: String? = privateGroup) -> String? {
        let data = privateGroup.flatMap { keychain.data(service: service, account: account, group: $0) }
            ?? keychain.data(service: service, account: account, group: nil)
        return data.flatMap { String(data: $0, encoding: .utf8) }
    }

    @discardableResult
    static func delete(account: String, in keychain: CredentialKeychain = SystemKeychain()) -> Bool {
        let status = keychain.delete(service: service, account: account, group: nil)
        return status == errSecSuccess || status == errSecItemNotFound
    }

    /// Accounts of every item this store holds, in any group.
    static func accounts(in keychain: CredentialKeychain = SystemKeychain()) -> [String] {
        keychain.items(service: service).map(\.account)
    }

    /// Every password this store holds, owner and per-account, and the NIP-46
    /// client keys. Factory reset calls it: the keys they unlock are gone, so
    /// the passwords must go too.
    @discardableResult
    static func deleteAll(in keychain: CredentialKeychain = SystemKeychain()) -> Bool {
        let status = keychain.delete(service: service, account: nil, group: nil)
        return status == errSecSuccess || status == errSecItemNotFound
    }
}

/// One keychain item's attributes, as `CredentialKeychain.items` lists them.
struct CredentialKeychainItem: Equatable {
    let account: String
    let group: String?
    let accessible: String?
}

/// The keychain calls CredentialStore makes, so its migration can be tested
/// against an in-memory keychain. A nil group means any group for a read,
/// update or delete, and the default group for an add.
protocol CredentialKeychain {
    func items(service: String) -> [CredentialKeychainItem]
    func data(service: String, account: String, group: String?) -> Data?
    func add(service: String, account: String, data: Data, group: String?, accessible: String) -> OSStatus
    func updateAccessible(service: String, account: String, group: String?, to accessible: String) -> OSStatus
    func delete(service: String, account: String?, group: String?) -> OSStatus
}

struct SystemKeychain: CredentialKeychain {
    private func query(service: String, account: String?, group: String?) -> [String: Any] {
        var q: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
        ]
        if let account { q[kSecAttrAccount as String] = account }
        if let group { q[kSecAttrAccessGroup as String] = group }
        return q
    }

    func items(service: String) -> [CredentialKeychainItem] {
        var q = query(service: service, account: nil, group: nil)
        q[kSecReturnAttributes as String] = true
        q[kSecMatchLimit as String] = kSecMatchLimitAll
        var result: AnyObject?
        guard SecItemCopyMatching(q as CFDictionary, &result) == errSecSuccess,
              let rows = result as? [[String: Any]] else { return [] }
        return rows.compactMap { row in
            guard let account = row[kSecAttrAccount as String] as? String else { return nil }
            return CredentialKeychainItem(account: account,
                                          group: row[kSecAttrAccessGroup as String] as? String,
                                          accessible: row[kSecAttrAccessible as String] as? String)
        }
    }

    func data(service: String, account: String, group: String?) -> Data? {
        var q = query(service: service, account: account, group: group)
        q[kSecReturnData as String] = true
        q[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: AnyObject?
        guard SecItemCopyMatching(q as CFDictionary, &result) == errSecSuccess else { return nil }
        return result as? Data
    }

    func add(service: String, account: String, data: Data, group: String?, accessible: String) -> OSStatus {
        var q = query(service: service, account: account, group: group)
        q[kSecValueData as String] = data
        q[kSecAttrAccessible as String] = accessible
        return SecItemAdd(q as CFDictionary, nil)
    }

    func updateAccessible(service: String, account: String, group: String?, to accessible: String) -> OSStatus {
        let q = query(service: service, account: account, group: group)
        return SecItemUpdate(q as CFDictionary, [kSecAttrAccessible as String: accessible] as CFDictionary)
    }

    func delete(service: String, account: String?, group: String?) -> OSStatus {
        SecItemDelete(query(service: service, account: account, group: group) as CFDictionary)
    }
}
