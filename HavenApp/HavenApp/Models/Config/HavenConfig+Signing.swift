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
        let activeNpub = activeAccountNpub.isEmpty ? ownerNpub : activeAccountNpub

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
