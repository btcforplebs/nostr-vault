import Foundation

/// Who has vault space (Logen, 2026-11-12 14:19Z, undoing the 11-06
/// key-or-signer rule): the device owner, always, even npub-only (the engine
/// whitelists OWNER_NPUB itself), plus every account added on this device,
/// watch-only (npub only) included, like Haven. Whitelist-wide, not per
/// account: whoever holds the key of ANY listed npub can AUTH and read the
/// whole /private store and list history (the owner's included), the full
/// blob list and unposted blobs over the mesh (Tron, PR #1971 review). An
/// npub alone reads nothing gated, and every stored event still carries its
/// author's own signature.
///
/// `whitelistedNpubs` is the app's account list (kept in config.json);
/// `whitelisted_npubs.json` and the relay's launch inputs get
/// `vaultWhitelistNpubs`: the same list, trimmed, without the owner.
extension HavenConfig {
    /// The accounts for the whitelist file: every account other than the
    /// owner, in account order, no blanks, no repeats.
    var vaultWhitelistNpubs: [String] {
        let owner = ownerNpub.trimmingCharacters(in: .whitespacesAndNewlines)
        var seen = Set<String>()
        return whitelistedNpubs.compactMap { raw in
            let npub = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !npub.isEmpty, npub != owner, seen.insert(npub).inserted else {
                return nil
            }
            return npub
        }
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
    /// relay start.
    static func accountList(saved: [String], whitelistFile: [String]) -> [String] {
        var seen = Set(saved)
        return saved + whitelistFile.filter { seen.insert($0).inserted }
    }
}
