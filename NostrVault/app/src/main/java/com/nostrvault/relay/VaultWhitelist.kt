package com.nostrvault.relay

import com.nostrvault.data.local.CredentialStore

/**
 * Who the vault treats as its own (the engine's whitelist: post without AUTH, read /private and /lists, uploads,
 * inbox, imports). Logen's rule (2026-11-06 11:37Z): the device owner, always (even npub-only, through OWNER_NPUB),
 * plus every account with a key or a signer on THIS device. Nothing else: a watch-only account is often someone
 * else's public npub, and whoever holds its key could then write to this vault and read its private stores
 * (Tron's survey). The engine can't tell signing from watch-only, so the app enforces it here, and the relay's
 * whitelist file is rebuilt from it at every start ([RelayConfiguration.LaunchInputs.whitelist]): a key or signer
 * removed, or a stale entry from an older build, is gone at the next start. Twin of Apple's vault whitelist (Tim).
 */
object VaultWhitelist {
    /**
     * The accounts besides the owner that go in the whitelist file: those on this device that [canSign]. The owner
     * is not listed here; the engine adds OWNER_NPUB itself.
     */
    fun npubs(config: HavenConfig, canSign: (String) -> Boolean = { canSignHere(config, it) }): List<String> =
        config.allAccountNpubs()
            .map { it.trim() }
            .filter { it.isNotEmpty() && it != config.ownerNpub.trim() && canSign(it) }
            .distinct()

    /**
     * [npub] has a key or a signer on this device: a bunker, Amber, or a stored key. A key store that can't be read
     * counts as no key: the vault never grants access on a guess.
     */
    fun canSignHere(config: HavenConfig, npub: String): Boolean =
        config.bunkerConfig(npub) != null || config.signingMode(npub) == "amber" || runCatching {
            val hex = HavenBridge.decodeNpub(npub)
            CredentialStore.getCredentialHexKey(npub) != null || (hex != null && CredentialStore.getNsec(hex) != null)
        }.getOrDefault(false)
}
