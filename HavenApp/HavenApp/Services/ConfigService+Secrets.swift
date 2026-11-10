import Foundation

/// Keys at rest: the secrets config.json leaves out, filled back in from the
/// keychain at load and scrubbed from the copies beside it (HavenConfig+Secrets).
extension ConfigService {
    /// Fills in the NIP-46 client keys config.json leaves out, from the
    /// keychain, and notes any the file still held as plaintext.
    func attachKeychainSecrets() {
        // Added to, not replaced: a reload before the save that moves them
        // must not forget a scrub still owed.
        plaintextNIP46Secrets = Array(Set(plaintextNIP46Secrets).union(config.nip46ClientSecrets.values))
        var stored: [String: String] = [:]
        let dropped = config.attachNIP46ClientSecrets({ account in
            let value = CredentialStore.get(account: account)
            stored[account] = value
            return value
        }, pubkeyOf: Self.nip46ClientPubkey(ofSecret:))
        droppedNIP46Secrets = Array(Set(droppedNIP46Secrets).union(dropped))
        if !dropped.isEmpty {
            RelayProcessManager.shared.addLog("NIP-46: config.json held an app key the signer was not paired with; using the paired one from the keychain", level: "WARNING")
        }
        nip46Sync = NIP46SecretSync(synced: stored)

        // The wallet, backup and signer-link secrets (HavenConfig+ConfigSecrets).
        plaintextConfigSecrets = Array(Set(plaintextConfigSecrets).union(config.configSecrets.values))
        var storedOther: [String: String] = [:]
        config.attachConfigSecrets { account in
            let value = CredentialStore.get(account: account)
            storedOther[account] = value
            return value
        }
        configSecretSync = NIP46SecretSync(synced: storedOther)
    }

    /// The config as config.json gets it: without each secret the keychain holds.
    var diskConfig: HavenConfig {
        config.withoutNIP46ClientSecrets(inKeychain: nip46InKeychain)
            .withoutConfigSecrets(inKeychain: configSecretsInKeychain)
    }

    /// Writes the wallet, backup and signer-link secrets to the keychain
    /// before a save, so `diskConfig` leaves out each one it took.
    func syncConfigSecretsToKeychain() {
        configSecretsInKeychain = configSecretSync.sync(config.configSecrets,
                                                        store: { CredentialStore.store($0, account: $1) },
                                                        delete: { CredentialStore.delete(account: $0) })
    }

    /// Those secrets come out of the backup copies once config.json has been
    /// written without them: each one the keychain now holds, and each one
    /// the config no longer has at all (a wallet since disconnected or
    /// replaced), which no copy needs to keep.
    func scrubPlaintextConfigSecrets(_ store: ConfigFileStore) {
        guard !plaintextConfigSecrets.isEmpty else { return }
        let held = Set(configSecretsInKeychain.compactMap { configSecretSync.synced[$0] })
        let live = Set(config.configSecrets.values)
        let done = plaintextConfigSecrets.filter { held.contains($0) || !live.contains($0) }
        guard !done.isEmpty else { return }
        store.scrub(HavenConfig.scrubNeedles(for: done), replacingWith: HavenConfig.emptyJSONString)
        plaintextConfigSecrets.removeAll { done.contains($0) }
    }

    /// The hex pubkey of a NIP-46 client key, or nil if it is not one.
    static func nip46ClientPubkey(ofSecret hex: String) -> String? {
        guard !hex.isEmpty, let pk = withCStrings([hex], { p in GetPublicKeyC(p[0]) }) else { return nil }
        defer { free(pk) }
        let value = String(cString: pk)
        return value.isEmpty ? nil : value
    }

    /// Client keys that were plaintext in config.json come out of the backup
    /// copies once the keychain holds them and config.json has been written
    /// without them.
    func scrubPlaintextNIP46Secrets(_ store: ConfigFileStore) {
        if !droppedNIP46Secrets.isEmpty {
            let live = Set(config.nip46ClientSecrets.values)
            let gone = droppedNIP46Secrets.filter { !live.contains($0) }
            store.scrub(gone)
            droppedNIP46Secrets.removeAll()
            plaintextNIP46Secrets.removeAll { gone.contains($0) }
        }
        guard !plaintextNIP46Secrets.isEmpty else { return }
        let held = Set(nip46InKeychain.compactMap { nip46Sync.synced[$0] })
        let done = plaintextNIP46Secrets.filter { held.contains($0) }
        guard !done.isEmpty else { return }
        store.scrub(done)
        plaintextNIP46Secrets.removeAll { held.contains($0) }
    }
}
