package com.nostrvault.data.model

/**
 * Which account a note goes out as. The signer reads the account that is
 * active when it signs, and a note can wait seconds for its media to upload
 * before that — long enough for a switch (the profile-picture menu, a tapped
 * notification for another account). So the account is locked when Post is
 * tapped and checked again once the note is signed.
 * Port of `PostingAccount` in HavenApp/Models/QueuedMediaPost.swift.
 */
object PostingAccount {
    /** The account locked when Post was tapped. */
    data class Lock(val npub: String, val hex: String)

    /** Thrown instead of signing or publishing as an account switched to after Post. */
    class AccountChangedException(message: String = MESSAGE) : IllegalStateException(message)

    const val MESSAGE = "The account changed while this was posting, so it was not sent. Switch back and post again."
    const val NOTE_MESSAGE = "The account changed while this note was posting, so it was not sent. Your note is saved as a draft."

    /** The account a post is for: the active one, or the owner when none is set. */
    fun resolve(active: String?, owner: String): String =
        active?.trim().orEmpty().ifEmpty { owner }

    /**
     * True only when the account active now is still the one locked at Post,
     * and the signed note carries that account's key. Anything else must not
     * be published.
     */
    fun signedAsLocked(lock: Lock, activeNow: String?, owner: String, eventPubkey: String): Boolean {
        if (lock.hex.isEmpty()) return false
        return resolve(activeNow, owner) == lock.npub && eventPubkey.equals(lock.hex, ignoreCase = true)
    }
}
