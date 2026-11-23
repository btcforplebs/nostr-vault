import Foundation

/// A plaintext owner key at rest (PlainOwnerKeyAtRest): kept in the keychain,
/// never newly written to config.json, and an older build's copy in the file
/// removed only once the keychain holds it. Also tracks whether the owner's
/// key is saved on this device at all, for OwnerKeyNotSavedAlert.
extension ConfigService {
    /// At load, after config.json is read: fills in a key the file left out
    /// from the keychain, if it is this owner's. Another account's (left by
    /// an earlier install) is deleted.
    func attachPlainOwnerKey() {
        let account = PlainOwnerKeyAtRest.account
        let stored = CredentialStore.get(account: account)
        let npub = config.ownerNpub
        let loaded = PlainOwnerKeyAtRest.loaded(fromFile: config.ownerNsec, stored: stored) { key in
            Self.plainOwnerKeyOwnership(key, npub: npub)
        }
        if loaded.deleteStored {
            _ = CredentialStore.delete(account: account)
            RelayProcessManager.shared.addLog("Removed a keychain owner key that belongs to another account", level: "WARNING")
        }
        plainOwnerKey = loaded.state
        // Until the next save decides, config.json keeps what it holds now.
        plainOwnerKeyOnDisk = loaded.state.inFile
        if config.ownerNsec != loaded.key { config.ownerNsec = loaded.key }
    }

    /// Whether `key` (nsec or hex) is `npub`'s. Only a proven mismatch is
    /// `.other`, as in SetupStoredOwnerKey.
    static func plainOwnerKeyOwnership(_ key: String, npub: String) -> PlainOwnerKeyAtRest.Ownership {
        let plain = key.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let hexKey = NpubValidation.hexSecretKey(fromNsec: plain)
                ?? (plain.range(of: "^[a-f0-9]{64}$", options: .regularExpression) != nil ? plain : nil),
              let expected = NpubValidation.hexPubkey(fromNpub: npub.trimmingCharacters(in: .whitespacesAndNewlines)),
              let pk = withCStrings([hexKey], { p in GetPublicKeyC(p[0]) }) else { return .unreadable }
        defer { free(pk) }
        let derived = String(cString: pk)
        guard !derived.isEmpty else { return .unreadable }
        return derived.lowercased() == expected.lowercased() ? .matches : .other
    }

    /// Before config.json is written: stores the key in the keychain and
    /// decides what the file gets.
    func preparePlainOwnerKeySave() {
        let account = PlainOwnerKeyAtRest.account
        let decision = plainOwnerKey.prepareSave(config.ownerNsec) { key in
            CredentialStore.store(key, account: account) && CredentialStore.get(account: account) == key
        }
        if decision.notSaved, !plainOwnerKeyRefused {
            RelayProcessManager.shared.addLog("Owner key not saved: the keychain refused it, and it is not written to config.json", level: "ERROR")
        }
        plainOwnerKeyOnDisk = decision.onDisk
        plainOwnerKeyRefused = decision.notSaved
        // No encrypted key left, so no password it needs.
        if config.ownerNcryptsec.isEmpty { ownerPasswordRefused = false }
        updateOwnerKeyNotSaved()
    }

    /// After config.json was written: drops a keychain copy the config no
    /// longer has, and scrubs a key that just left the file from the copies
    /// beside it.
    func finishPlainOwnerKeySave(_ store: ConfigFileStore) {
        let moved = plainOwnerKey.didSave(onDisk: plainOwnerKeyOnDisk, current: config.ownerNsec) {
            CredentialStore.delete(account: PlainOwnerKeyAtRest.account)
        }
        guard let moved else { return }
        store.scrub(HavenConfig.scrubNeedles(for: [moved]), replacingWith: HavenConfig.emptyJSONString)
        RelayProcessManager.shared.addLog("Moved a plaintext owner key from config.json to the keychain", level: "INFO")
    }

    /// Stores the password a new owner key was encrypted with. Raises the
    /// warning when the keychain refuses it: the encrypted key is in
    /// config.json, but this device cannot open it after the app closes.
    @discardableResult
    func storeOwnerPassword(_ password: String) -> Bool {
        let ok = NIP49Service.storePasswordInKeychain(password)
            && NIP49Service.getPasswordFromKeychain() == password
        if !ok {
            RelayProcessManager.shared.addLog("Owner key password not saved: the keychain refused it", level: "ERROR")
        }
        ownerPasswordRefused = !ok
        updateOwnerKeyNotSaved()
        return ok
    }

    func updateOwnerKeyNotSaved() {
        let notSaved = plainOwnerKeyRefused || ownerPasswordRefused
        if ownerKeyNotSaved != notSaved { ownerKeyNotSaved = notSaved }
    }

    /// Factory reset: the keychain copy goes with ResetLeftovers.
    func forgetPlainOwnerKeyState() {
        plainOwnerKey = PlainOwnerKeyAtRest()
        plainOwnerKeyOnDisk = ""
        plainOwnerKeyRefused = false
        ownerPasswordRefused = false
        updateOwnerKeyNotSaved()
    }
}
