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

    /// Fills in each client key from `stored` (the keychain). Where the
    /// keychain and config.json disagree, the key the signer was paired with
    /// wins, told by the pubkey the pairing saved (`clientPubkey`), which
    /// stays in the file:
    /// - a file key that is not the paired one was made by a build that could
    ///   not read the keychain, found the file blank and made a fresh key
    ///   (2.7.2 over 3.0.0, LogePhone 2026-10-27): the keychain wins;
    /// - a file key that is the paired one comes from pairing again on such a
    ///   build: the file wins, and the next save stores it.
    /// When the pubkeys can't decide (none saved, or the file key isn't it),
    /// the keychain wins. A key only the file holds is kept. `pubkeyOf`
    /// derives a key's hex pubkey. Returns the file keys that lost, so their
    /// plaintext copies can be scrubbed.
    @discardableResult
    mutating func attachNIP46ClientSecrets(_ stored: (String) -> String?,
                                           pubkeyOf: (String) -> String?) -> [String] {
        var dropped: [String] = []
        func pick(file: String, keychain: String?, paired: String) -> String {
            guard let keychain, !keychain.isEmpty, keychain != file else { return file }
            guard !file.isEmpty else { return keychain }
            let pairedLower = paired.lowercased()
            if !pairedLower.isEmpty, pubkeyOf(file)?.lowercased() == pairedLower { return file }
            dropped.append(file)
            return keychain
        }
        // The shared slot mirrors the active account: its entry's pubkey is
        // the paired one. nip46ClientPubkey is rewritten along with a fresh
        // key, so it is used only for an owner with no entry yet.
        let activeNpub = activeAccountNpub.isEmpty ? ownerNpub : activeAccountNpub
        let sharedPaired = accountBunkerConfigs[activeNpub]?.clientPubkey ?? nip46ClientPubkey
        nip46ClientSecretKey = pick(file: nip46ClientSecretKey,
                                    keychain: stored(Self.nip46ClientSecretAccount),
                                    paired: sharedPaired)
        for (npub, cfg) in accountBunkerConfigs {
            accountBunkerConfigs[npub]?.clientSecretKey = pick(
                file: cfg.clientSecretKey,
                keychain: stored(Self.nip46ClientSecretAccount(forNpub: npub)),
                paired: cfg.clientPubkey)
        }
        return dropped
    }

    /// The client key an account's signer was paired with, when the live
    /// config lost it: the account's own entry, then the keychain's copy for
    /// that account. The shared slot in the keychain is used only for an
    /// account with no entry of its own (the owner straight after setup); it
    /// may hold another account's key otherwise. Nil: no paired key exists.
    func pairedNIP46ClientSecret(forNpub npub: String, stored: (String) -> String?) -> String? {
        if let cfg = accountBunkerConfigs[npub] {
            if !cfg.clientSecretKey.isEmpty { return cfg.clientSecretKey }
            if let v = stored(Self.nip46ClientSecretAccount(forNpub: npub)), !v.isEmpty { return v }
            return nil
        }
        if let v = stored(Self.nip46ClientSecretAccount), !v.isEmpty { return v }
        return nil
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
            } else if synced[account] != nil, delete(account) {
                // The keychain refused the new key but still holds the old
                // one, which would win at the next load: drop it, so the file
                // (which keeps the new key) is the only copy.
                synced[account] = nil
            }
        }
        for account in synced.keys where current[account] == nil {
            if delete(account) { synced[account] = nil }
        }
        return held
    }
}
