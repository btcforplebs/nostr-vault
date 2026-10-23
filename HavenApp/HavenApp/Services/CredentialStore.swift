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
    /// widget carries too; this one the widget and share extension do not.
    /// Not private from the team: the wildcard profile (`525WQ48Y72.*`) lets
    /// any app signed by this team claim it. nil on the Mac, whose login
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

    /// The owner password, or the status of a read that found none:
    /// `errSecItemNotFound` is the only status that means there is no password.
    static func lookUpOwnerPassword() -> (password: String?, status: OSStatus) {
        lookUp(account: ownerAccount)
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
    /// Every keychain service the migration moves: these passwords and the
    /// NIP-46 client keys, and the FIPS mesh key (FipsMeshService), a private
    /// key of its own.
    static let migratedServices = [service, MeshIdentityReset.keychainService]

    @discardableResult
    static func migrateToThisDeviceOnly(in keychain: CredentialKeychain = SystemKeychain(),
                                        privateGroup: String? = privateGroup) -> Int {
        migratedServices.reduce(0) { $0 + migrate(service: $1, in: keychain, privateGroup: privateGroup) }
    }

    private static func migrate(service: String, in keychain: CredentialKeychain,
                                privateGroup: String?) -> Int {
        var moved = 0
        for item in keychain.items(service: service)
        where item.group != privateGroup || item.accessible != accessible {
            // Every call below names the item's own group. A nil group would
            // mean any group, and the delete would take the copy just added.
            guard let group = item.group else { continue }
            if let privateGroup, group != privateGroup {
                guard let data = keychain.data(service: service, account: item.account, group: group) else { continue }
                let status = keychain.add(service: service, account: item.account, data: data,
                                          group: privateGroup, accessible: accessible)
                // A duplicate is a newer value already stored privately.
                guard status == errSecSuccess || status == errSecDuplicateItem else { continue }
                if keychain.delete(service: service, account: item.account, group: group) == errSecSuccess {
                    moved += 1
                }
            } else if keychain.updateAccessible(service: service, account: item.account,
                                                group: group, to: accessible) == errSecSuccess {
                moved += 1
            }
        }
        return moved
    }

    /// Where the owner password and the mesh key sit, for one launch log
    /// line: a device log then shows the migration ran, with no probe app.
    /// Names groups only, never values.
    static func locationReport(in keychain: CredentialKeychain = SystemKeychain()) -> String {
        func place(_ service: String, _ account: String) -> String {
            let groups = keychain.items(service: service).filter { $0.account == account }.map { $0.group ?? "no group" }
            return groups.isEmpty ? "none" : groups.joined(separator: " + ")
        }
        return "owner password in \(place(service, ownerAccount)); mesh key in \(place(MeshIdentityReset.keychainService, "mesh-nsec"))"
    }

    // MARK: - Any secret, by account name

    @discardableResult
    static func store(_ value: String, account: String,
                      in keychain: CredentialKeychain = SystemKeychain(),
                      privateGroup: String? = privateGroup) -> Bool {
        guard let data = value.data(using: .utf8) else { return false }
        // Write first, then drop copies elsewhere: a failed write must leave
        // the old value, which may be the only way to decrypt a key.
        var group = privateGroup
        var status = write(data, account: account, group: group, in: keychain)
        if status == errSecMissingEntitlement, privateGroup != nil {
            // A build without the private group entitled: the default group
            // still beats losing the value.
            group = nil
            status = write(data, account: account, group: nil, in: keychain)
        }
        guard status == errSecSuccess else { return false }
        if let group {
            for item in keychain.items(service: service)
            where item.account == account && item.group != nil && item.group != group {
                _ = keychain.delete(service: service, account: account, group: item.group)
            }
        }
        return true
    }

    /// Adds the item, or replaces the value of the one already in `group`.
    private static func write(_ data: Data, account: String, group: String?,
                              in keychain: CredentialKeychain) -> OSStatus {
        let status = keychain.add(service: service, account: account, data: data,
                                  group: group, accessible: accessible)
        guard status == errSecDuplicateItem else { return status }
        return keychain.updateData(service: service, account: account, group: group,
                                   data: data, accessible: accessible)
    }

    /// The private group first; any other group only holds an item the
    /// migration has not moved yet.
    static func get(account: String,
                    in keychain: CredentialKeychain = SystemKeychain(),
                    privateGroup: String? = privateGroup) -> String? {
        lookUp(account: account, in: keychain, privateGroup: privateGroup).password
    }

    static func lookUp(account: String,
                       in keychain: CredentialKeychain = SystemKeychain(),
                       privateGroup: String? = privateGroup) -> (password: String?, status: OSStatus) {
        var read = (data: nil as Data?, status: errSecItemNotFound)
        if let privateGroup { read = keychain.read(service: service, account: account, group: privateGroup) }
        if read.data == nil, read.status == errSecItemNotFound {
            read = keychain.read(service: service, account: account, group: nil)
        }
        guard let data = read.data else { return (nil, read.status) }
        return (String(data: data, encoding: .utf8), errSecSuccess)
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
    func read(service: String, account: String, group: String?) -> (data: Data?, status: OSStatus)
    func add(service: String, account: String, data: Data, group: String?, accessible: String) -> OSStatus
    func updateData(service: String, account: String, group: String?, data: Data, accessible: String) -> OSStatus
    func updateAccessible(service: String, account: String, group: String?, to accessible: String) -> OSStatus
    func delete(service: String, account: String?, group: String?) -> OSStatus
}

extension CredentialKeychain {
    func data(service: String, account: String, group: String?) -> Data? {
        read(service: service, account: account, group: group).data
    }
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

    func read(service: String, account: String, group: String?) -> (data: Data?, status: OSStatus) {
        var q = query(service: service, account: account, group: group)
        q[kSecReturnData as String] = true
        q[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: AnyObject?
        let status = SecItemCopyMatching(q as CFDictionary, &result)
        return (status == errSecSuccess ? result as? Data : nil, status)
    }

    func updateData(service: String, account: String, group: String?, data: Data, accessible: String) -> OSStatus {
        let q = query(service: service, account: account, group: group)
        let attrs: [String: Any] = [kSecValueData as String: data, kSecAttrAccessible as String: accessible]
        return SecItemUpdate(q as CFDictionary, attrs as CFDictionary)
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
