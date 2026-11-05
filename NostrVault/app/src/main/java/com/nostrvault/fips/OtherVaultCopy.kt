package com.nostrvault.fips

/**
 * The rules for "Copy from my other vault" over the mesh, on both ends. Twin of iOS `OtherVaultCopy.swift` (#1776).
 *
 * The source phone (A) shares its vault with its own linked devices for [SHARE_WINDOW_MS] after a link, even with
 * Share off, so the new phone (B) can copy from it. B dials A every [DIAL_RETRY_S] for up to [DIAL_WINDOW_S] before
 * it falls back to the relays: a phone that was just linked is often still finding the other one on the mesh.
 */
object OtherVaultCopy {
    /** How long A shares with its own devices after a link (sharing off). */
    const val SHARE_WINDOW_MS = 15 * 60 * 1000L

    /** B: how long it keeps dialing the other vault before falling back to the relays. */
    const val DIAL_WINDOW_S = 60L
    const val DIAL_RETRY_S = 10L

    /** How long B keeps the other vault's lasting address, for a cut setup or older_relays to read it again. */
    const val KEEP_LINK_MS = 24 * 60 * 60 * 1000L

    const val KEEP_OPEN_LINE = "Keep Nostr Vault open on this device while your other device copies from it."

    /** B dials again when one more try still starts inside the window (iOS `dialsAgain`). */
    fun dialsAgain(startedAt: Long, now: Long): Boolean = now - startedAt + DIAL_RETRY_S < DIAL_WINDOW_S

    /** A starts the copy share after a link: the mesh is running and the person hasn't turned sharing on already. */
    fun sharesAfterLink(meshOn: Boolean, alreadySharing: Boolean): Boolean = meshOn && !alreadySharing

    /** A window that ends at [until] (the copy share, B's kept address) is still open at [now]. */
    fun open(until: Long, now: Long): Boolean = now < until
}
