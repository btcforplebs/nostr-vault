package com.nostrvault.service.deleted

import kotlinx.serialization.Serializable

/**
 * A copy of one of your own posts, saved on this device just before its
 * NIP-09 delete request (kind 5) went out. Port of iOS `DeletedPost.swift`.
 *
 * Nostr has no real undo: once the kind 5 is out, relays that honour it —
 * your own vault included — refuse the original event id for good. So
 * un-delete publishes the saved text and tags again as a *new* event. It gets
 * a new id and today's time, and the likes and replies on the old id stay
 * with the old id.
 */
@Serializable
data class DeletedPost(
    /** The deleted event, exactly as it was signed. */
    val id: String,
    val pubkey: String,
    val createdAt: Long,
    val kind: Int,
    val tags: List<List<String>>,
    val content: String,
    val sig: String,
    /** When the delete was sent from this device, epoch milliseconds. */
    val deletedAt: Long,
) {
    /** What un-delete signs. */
    data class Draft(val kind: Int, val content: String, val tags: List<List<String>>)

    /**
     * The same kind, text and tags, so a deleted reply comes back as a reply
     * in the same thread. `created_at` is not carried over: the signer stamps
     * the moment of un-delete.
     *
     * Two tags are dropped. `nonce` claims proof of work for the *old* event
     * id, which the new id does not have; the signer mines a fresh one when
     * proof of work is on. `expiration` (NIP-40) may already have passed,
     * and relays refuse or drop an event that is already expired.
     */
    fun republishDraft(): Draft = Draft(kind, content, tags.filter { it.firstOrNull() !in DROPPED_TAGS })

    companion object {
        private val DROPPED_TAGS = setOf("nonce", "expiration")

        /**
         * Whether a deleted event of [kind] gets a copy. Replaceable and
         * addressable kinds (0, 3, 10000–19999, 30000–39999) do not: posted
         * again with today's time, an old version would replace whatever
         * newer version is live at that address.
         */
        fun keepsCopy(kind: Int): Boolean =
            !(kind == 0 || kind == 3 || kind in 10000 until 20000 || kind in 30000 until 40000)

        /** Words the Recently Deleted screen shows next to Un-delete. */
        const val UNDELETE_NOTE =
            "Un-delete posts it again as a new post. Likes and replies on the old post don't come back."
    }
}
