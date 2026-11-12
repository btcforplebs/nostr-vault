import Foundation

/// Two sets (Logen, 2026-11-12, PR #1971 option a):
///
/// - Vault space: the device owner, always, even npub-only (the engine
///   whitelists OWNER_NPUB itself), plus every account added on this device,
///   watch-only (npub only) included, like Haven. Each keeps its own notes
///   and uploads here. `whitelisted_npubs.json` gets `vaultWhitelistNpubs`.
/// - Private reads (/private, list history, the full blob list, unposted
///   blobs over the mesh): the owner plus the accounts with a key or signer
///   on this device only. An added npub is often someone else's, and whoever
///   holds its nsec could AUTH as it (Tron, PR #1971 review).
///   `private_reader_npubs.json` gets `vaultPrivateReaderNpubs`; the engine
///   adds the owner and fails closed to the owner alone if the file is
///   unreadable (haven-go/whitelist.go privateReaders).
///
/// `whitelistedNpubs` is the app's account list (kept in config.json).
extension HavenConfig {
    /// The private-readers file the engine reads (PRIVATE_READER_NPUBS_FILE).
    static let privateReaderNpubsFile = "private_reader_npubs.json"

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

    /// The accounts for the private-readers file: those of
    /// `vaultWhitelistNpubs` with a key or signer on this device.
    var vaultPrivateReaderNpubs: [String] {
        vaultWhitelistNpubs.filter { canSignOnThisDevice(npub: $0) }
    }

    /// A stored key (ncryptsec) or a signer (bunker) for `npub` here.
    func canSignOnThisDevice(npub: String) -> Bool {
        hasStoredCredential(npub: npub) || hasSigner(npub: npub)
    }

    /// Writes both account files beside the relay: every writer goes through
    /// here (save, relay start, backup restore, import).
    static func writeVaultAccountFiles(whitelist: [String], readers: [String], whitelistFile: String,
                                       under dir: URL, encoder: JSONEncoder) {
        if let data = try? encoder.encode(whitelist) {
            try? data.write(to: dir.appendingPathComponent(whitelistFile))
        }
        if let data = try? encoder.encode(readers) {
            try? data.write(to: dir.appendingPathComponent(privateReaderNpubsFile))
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
