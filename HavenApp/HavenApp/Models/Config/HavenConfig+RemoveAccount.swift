import Foundation

extension HavenConfig {
    /// Drops everything this config keeps for one account, keyed by its npub.
    ///
    /// Removing an account used to clear only its key, signer and signing
    /// mode. Its blocks stayed in `blockedNpubsPerAccount`, and
    /// `allBlockedNpubsAcrossAccounts` merges every entry into the relay's
    /// device-wide blacklist, so the removed account's blocks kept blocking
    /// people for every account with nothing in the app able to undo it.
    ///
    /// The owner is never removed here: its blocks also live in
    /// `blacklistedNpubs` and its key in the owner fields.
    mutating func removeAccountEntries(npub raw: String) {
        let npub = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !npub.isEmpty, npub != ownerNpub else { return }
        whitelistedNpubs.removeAll { $0.trimmingCharacters(in: .whitespacesAndNewlines) == npub }
        accountCredentials.removeValue(forKey: npub)
        accountBunkerConfigs.removeValue(forKey: npub)
        accountSigningModes.removeValue(forKey: npub)
        publishRelayListPerAccount.removeValue(forKey: npub)
        notificationPrefsPerAccount.removeValue(forKey: npub)
        blockedNpubsPerAccount.removeValue(forKey: npub)
        blockedNpubsLastSyncTimestamp.removeValue(forKey: npub)
    }
}
