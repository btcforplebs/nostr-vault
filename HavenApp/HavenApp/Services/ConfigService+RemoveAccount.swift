import Foundation

extension ConfigService {
    /// Removes one account from this device: its key, its signer and every
    /// per-account setting, then pushes the smaller blocked list to the relay.
    /// Both remove paths in Settings › Accounts call this, so neither can
    /// leave the account's blocks behind (see `removeAccountEntries`).
    func removeAccount(npub raw: String) {
        let npub = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !npub.isEmpty, npub != config.ownerNpub else { return }
        config.whitelistedNpubs.removeAll { $0.trimmingCharacters(in: .whitespacesAndNewlines) == npub }
        removeBunkerConfig(forNpub: npub)
        // Switch away only after the bunker config is gone: removeBunkerConfig
        // already detaches the active signer, and its session drop must land
        // before the owner's connect, which can share the same signer session.
        if config.activeAccountNpub.trimmingCharacters(in: .whitespacesAndNewlines) == npub {
            switchActiveAccount(to: nil)
        }
        removeCredential(forNpub: npub)
        config.removeAccountEntries(npub: npub)
        save()
        syncBlacklistToRelay()
        NotificationCenter.default.post(name: NSNotification.Name("BlockedAccountsUpdated"), object: nil)
    }
}
