import Foundation

/// The NIP-46 client keys live in the keychain (CredentialStore), not in
/// config.json: the file is in an encrypted device backup, and a restored
/// copy of a client key keeps an authorized remote-signing session. In memory
/// they stay on `HavenConfig`, so every reader and writer is unchanged;
/// ConfigService syncs them to the keychain on save and fills them back in on
/// load, and the copy it writes to disk leaves out each key the keychain holds.
extension HavenConfig {
    static let nip46ClientSecretAccount = "nip46-client-secret"

    static func nip46ClientSecretAccount(forNpub npub: String) -> String {
        "nip46-client-secret-\(npub)"
    }

    /// Every NIP-46 client key in this config, by keychain account. Empty
    /// values are left out.
    var nip46ClientSecrets: [String: String] {
        var out: [String: String] = [:]
        if !nip46ClientSecretKey.isEmpty { out[Self.nip46ClientSecretAccount] = nip46ClientSecretKey }
        for (npub, cfg) in accountBunkerConfigs where !cfg.clientSecretKey.isEmpty {
            out[Self.nip46ClientSecretAccount(forNpub: npub)] = cfg.clientSecretKey
        }
        return out
    }

    /// Fills in each client key the file left out from `stored`. A key the
    /// file still holds (a config from before this build) wins: it is what
    /// the session was running on.
    mutating func attachNIP46ClientSecrets(_ stored: (String) -> String?) {
        if nip46ClientSecretKey.isEmpty, let v = stored(Self.nip46ClientSecretAccount) {
            nip46ClientSecretKey = v
        }
        for npub in accountBunkerConfigs.keys where accountBunkerConfigs[npub]?.clientSecretKey.isEmpty == true {
            if let v = stored(Self.nip46ClientSecretAccount(forNpub: npub)) {
                accountBunkerConfigs[npub]?.clientSecretKey = v
            }
        }
    }

    /// The config as written to disk: without each client key whose keychain
    /// account is in `inKeychain`. A key the keychain did not take stays in
    /// the file, so a failed keychain write never loses a session.
    func withoutNIP46ClientSecrets(inKeychain: Set<String>) -> HavenConfig {
        var copy = self
        if inKeychain.contains(Self.nip46ClientSecretAccount) { copy.nip46ClientSecretKey = "" }
        for npub in copy.accountBunkerConfigs.keys
        where inKeychain.contains(Self.nip46ClientSecretAccount(forNpub: npub)) {
            copy.accountBunkerConfigs[npub]?.clientSecretKey = ""
        }
        return copy
    }
}

/// Keeps the keychain's NIP-46 client keys in step with the config.
/// `synced` is what the keychain is known to hold, by account: only a key it
/// held and the config has since dropped is deleted, so a load that could
/// not read the keychain (before the first unlock) never deletes anything.
struct NIP46SecretSync {
    private(set) var synced: [String: String] = [:]

    init(synced: [String: String] = [:]) { self.synced = synced }

    /// Writes changed keys, deletes dropped ones, and returns the accounts
    /// the keychain now holds the current value for.
    mutating func sync(_ current: [String: String],
                       store: (String, String) -> Bool,
                       delete: (String) -> Bool) -> Set<String> {
        var held: Set<String> = []
        for (account, value) in current {
            if synced[account] == value || store(value, account) {
                synced[account] = value
                held.insert(account)
            }
        }
        for account in synced.keys where current[account] == nil {
            if delete(account) { synced[account] = nil }
        }
        return held
    }
}
