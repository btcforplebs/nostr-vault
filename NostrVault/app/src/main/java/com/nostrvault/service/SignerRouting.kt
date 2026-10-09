package com.nostrvault.service

import com.nostrvault.relay.HavenConfig

/**
 * Which signer an event goes to. Pure, so the routing rule is testable
 * without the native library.
 *
 * The rule (#168 parity): an owner-forced event (relay AUTH 22242, Blossom
 * auth, the 10050 / 10063 lists) is routed by the OWNER's own signing mode,
 * never the active account's. Sending it to the active account's bunker or
 * Amber asked the wrong signer for a key it does not hold: a doomed request,
 * possibly an approval prompt on the wrong account. With no usable owner
 * signer it fails closed; it never falls back to the active account's.
 */
sealed class SignerRoute {
    /** Sign with the local key of the owner (forceOwner) or the active account. */
    data class Local(val asOwner: Boolean) : SignerRoute()
    /** Through the active account's bunker session. */
    object ActiveBunker : SignerRoute()
    /** Through a specific signer's live session, without making it active. */
    data class BunkerSession(val signerPubkey: String) : SignerRoute()
    /** Through Amber. [asOwner]: signing for the owner while another account is active. */
    data class Amber(val asOwner: Boolean) : SignerRoute()
    /** No usable signer for this event. */
    data class Unavailable(val reason: String) : SignerRoute()
}

object SignerRouting {
    fun route(config: HavenConfig, forceOwner: Boolean, ownerHex: String, activeHex: String): SignerRoute {
        val ownerIsActive = !forceOwner || ownerHex == activeHex
        if (ownerIsActive) {
            return when (config.activeSigningMode()) {
                "nip46" -> SignerRoute.ActiveBunker
                "amber" -> SignerRoute.Amber(asOwner = false)
                else -> SignerRoute.Local(asOwner = forceOwner)
            }
        }
        val ownerNpub = config.ownerNpub
        return when (config.effectiveSigningMode(ownerNpub)) {
            "nip46" -> {
                val signer = config.bunkerConfig(ownerNpub)?.signerPubkey.orEmpty()
                if (signer.isEmpty()) SignerRoute.Unavailable("The owner's bunker has no signer key")
                else SignerRoute.BunkerSession(signer)
            }
            "amber" -> SignerRoute.Amber(asOwner = true)
            "local" -> SignerRoute.Local(asOwner = true)
            else -> SignerRoute.Unavailable("No signer for the owner account")
        }
    }
}
