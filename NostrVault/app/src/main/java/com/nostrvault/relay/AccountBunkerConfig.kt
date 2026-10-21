package com.nostrvault.relay

/**
 * Per-account NIP-46 remote-signer (bunker) configuration.
 * Mirrors iOS AccountBunkerConfig. Non-secret metadata is persisted in config
 * JSON; the clientSecretKey is sensitive but kept here for parity with iOS
 * (the bunker session needs it to reconnect on account switch).
 */
@kotlinx.serialization.Serializable
data class AccountBunkerConfig(
    val bunkerURI: String = "",
    val signerPubkey: String = "",
    val relayURL: String = "",
    val secret: String = "",
    val clientSecretKey: String = "",
    val clientPubkey: String = "",
) {
    val isConfigured: Boolean
        get() = bunkerURI.isNotEmpty() || signerPubkey.isNotEmpty()
}
