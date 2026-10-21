import Foundation

extension HavenConfig {
    // MARK: - Per-Account Signing Mode

    /// Copies the flat nip46* fields into the owner's per-account bunker config.
    /// Setup writes only the flat fields, but activeSigningMode() reads only the
    /// per-account dict — without this the first session after bunker setup
    /// resolves to "local" and every post fails.
    mutating func adoptGlobalBunkerConfigForOwner() {
        guard signingMode == "nip46", !ownerNpub.isEmpty, accountBunkerConfigs[ownerNpub] == nil,
              !nip46BunkerURI.isEmpty || !nip46SignerPubkey.isEmpty else { return }
        accountBunkerConfigs[ownerNpub] = AccountBunkerConfig(
            bunkerURI: nip46BunkerURI,
            signerPubkey: nip46SignerPubkey,
            relayURL: nip46RelayURL,
            secret: nip46Secret,
            clientSecretKey: nip46ClientSecretKey,
            clientPubkey: nip46ClientPubkey
        )
    }

    /// Returns the signing mode for the currently active account.
    /// Respects explicit user preference in accountSigningModes if set,
    /// otherwise falls back to auto-detection based on available credentials.
    func activeSigningMode() -> String {
        signingMode(for: activeAccountNpub.isEmpty ? ownerNpub : activeAccountNpub)
    }

    /// Whether owner-forced events (the local relay's NIP-42 AUTH) go to the
    /// owner's remote signer. Read from the owner's own signing mode, explicit
    /// or found from its bunker config, never the active account's: a bunker
    /// set up in the wizard has no `accountSigningModes` entry.
    var ownerSignsWithBunker: Bool {
        !ownerNpub.isEmpty && signingMode(for: ownerNpub) == "nip46"
    }

    /// The key the Go core files a bunker session under: the link's host (the
    /// remote signer), else the stored signer key. For bunkers such as Clave
    /// the host is not the account's own signerPubkey.
    static func signerSessionKey(bunkerURI: String, signerPubkey: String) -> String {
        URLComponents(string: bunkerURI)?.host ?? signerPubkey
    }

    /// The Go session key of the owner's bunker, or nil without one.
    var ownerSessionKey: String? {
        guard let cfg = accountBunkerConfigs[ownerNpub] else { return nil }
        let key = Self.signerSessionKey(bunkerURI: cfg.bunkerURI, signerPubkey: cfg.signerPubkey)
        return key.isEmpty ? nil : key
    }

    /// A pairing secret for the owner's bunker is still pending: the signer
    /// has not accepted this client yet. That login must reach the signer and
    /// may need an approval, so it is never made in the background.
    var ownerPairingPending: Bool {
        guard let cfg = accountBunkerConfigs[ownerNpub] else { return false }
        if !cfg.secret.isEmpty { return true }
        return URLComponents(string: cfg.bunkerURI)?.queryItems?
            .contains { $0.name == "secret" && !($0.value ?? "").isEmpty } ?? false
    }

    /// The owner's bunker link as the Go login takes it, built from the signer
    /// key and relay when no link was stored. No secret: a pending pairing is
    /// never logged in from here (`ownerPairingPending`).
    var ownerBunkerLink: String? {
        guard let cfg = accountBunkerConfigs[ownerNpub] else { return nil }
        if !cfg.bunkerURI.isEmpty { return cfg.bunkerURI }
        guard !cfg.signerPubkey.isEmpty, !cfg.relayURL.isEmpty else { return nil }
        return "bunker://\(cfg.signerPubkey)?relay=\(cfg.relayURL)"
    }

    /// Whether the owner's bunker session has to be opened in the background:
    /// the owner signs with a bunker, but another account is active, so the
    /// active-signer connect at launch never logs the owner in.
    var ownerNeedsBackgroundSession: Bool {
        ownerSignsWithBunker && !activeAccountNpub.isEmpty && activeAccountNpub != ownerNpub
    }

    /// Whether the owner can sign owner-forced events, whichever account is
    /// active. `hasNcryptsecPassword` is asked only for an ncryptsec owner:
    /// without the stored password the key can't be decrypted.
    func ownerCanSign(hasNcryptsecPassword: @autoclosure () -> Bool) -> Bool {
        if ownerSignsWithBunker { return true }
        if !ownerNcryptsec.isEmpty { return hasNcryptsecPassword() }
        return !(ownerHexKey ?? "").isEmpty
    }

    /// The signing mode `activeNpub` would sign with if it were active: the
    /// same rules as activeSigningMode(), for any account.
    func signingMode(for activeNpub: String) -> String {
        // Check explicit user preference first
        if let preferred = accountSigningModes[activeNpub] {
            // Validate the preference is still usable
            if preferred == "nip46" {
                if let cfg = accountBunkerConfigs[activeNpub], !cfg.bunkerURI.isEmpty || !cfg.signerPubkey.isEmpty {
                    return "nip46"
                }
                // Bunker config was removed — fall through to auto-detect
            } else if preferred == "local" {
                return "local"
            }
        }

        // Auto-detect: if a bunker config exists, use nip46
        if let cfg = accountBunkerConfigs[activeNpub], !cfg.bunkerURI.isEmpty || !cfg.signerPubkey.isEmpty {
            return "nip46"
        }

        // Fallback for initial setup: no npub exists yet, check flat config fields
        if activeNpub.isEmpty && signingMode == "nip46" && (!nip46SignerPubkey.isEmpty || !nip46BunkerURI.isEmpty) {
            return "nip46"
        }

        return "local"
    }
}
