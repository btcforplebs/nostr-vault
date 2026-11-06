import Foundation

/// Who has vault access (Logen, 2026-11-06 11:37Z): the device owner, always,
/// even npub-only (the engine whitelists OWNER_NPUB itself), plus every
/// account with a key or signer on this device. Nothing else: a watch-only
/// account is often someone else's npub, and a whitelisted key may post
/// without AUTH and read /private and /lists as the owner's reader.
///
/// `whitelistedNpubs` stays the app's account list (watch-only accounts
/// included, kept in config.json); `whitelisted_npubs.json` and the relay's
/// launch inputs get `vaultWhitelistNpubs` only.
extension HavenConfig {
    /// The accounts for the whitelist file: signing accounts other than the
    /// owner, in account order, no repeats.
    var vaultWhitelistNpubs: [String] {
        let owner = ownerNpub.trimmingCharacters(in: .whitespacesAndNewlines)
        var seen = Set<String>()
        return whitelistedNpubs.compactMap { raw in
            let npub = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !npub.isEmpty, npub != owner, canSignOnThisDevice(npub: npub), seen.insert(npub).inserted else {
                return nil
            }
            return npub
        }
    }

    /// A stored key (ncryptsec) or a signer (bunker) for `npub` here.
    func canSignOnThisDevice(npub: String) -> Bool {
        hasStoredCredential(npub: npub) || hasSigner(npub: npub)
    }

    func hasStoredCredential(npub: String) -> Bool {
        !(accountCredentials[npub] ?? "").isEmpty
    }

    func hasSigner(npub: String) -> Bool {
        guard let cfg = accountBunkerConfigs[npub] else { return false }
        return !cfg.bunkerURI.isEmpty || !cfg.signerPubkey.isEmpty
    }

    /// The account list at launch: config.json's, then any the whitelist
    /// file holds that it lacks (older builds kept the list only there).
    /// The file is rewritten from `vaultWhitelistNpubs` on the next save and
    /// relay start, so a stale watch-only entry loses access then.
    static func accountList(saved: [String], whitelistFile: [String]) -> [String] {
        var seen = Set(saved)
        return saved + whitelistFile.filter { seen.insert($0).inserted }
    }
}
