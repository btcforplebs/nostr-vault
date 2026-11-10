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
