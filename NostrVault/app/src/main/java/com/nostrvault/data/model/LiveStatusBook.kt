package com.nostrvault.data.model

/**
 * Who is live right now, for the red ring on their profile picture.
 *
 * Keeps the newest NIP-53 kind 30311 stream per address (a stream that has
 * since ended replaces its own live announcement), and answers "is this pubkey
 * hosting a stream that is on air and playable?" A pubkey counts only as the
 * host — the `p` tag marked Host, else the signer — never as a guest, the same
 * rule the Live tab uses. iOS: LiveStatusBook.
 *
 * Not thread-safe; [com.nostrvault.service.LiveStatusService] holds the lock.
 */
class LiveStatusBook {
    private val byAddress = mutableMapOf<String, LiveStream>()
    private val askedAt = mutableMapOf<String, Long>()

    /** Takes a stream in. @return true when it changed the book. */
    fun ingest(stream: LiveStream): Boolean {
        val existing = byAddress[stream.address]
        if (existing != null && existing.createdAt >= stream.createdAt) return false
        byAddress[stream.address] = stream
        return true
    }

    /** The newest live stream [pubkey] hosts at [nowSeconds], if any. */
    fun liveStream(hostedBy: String, nowSeconds: Long): LiveStream? =
        byAddress.values
            .filter { it.hostPubkey == hostedBy && it.isLiveAt(nowSeconds) }
            .maxByOrNull { it.createdAt }

    /** Every pubkey hosting a live stream at [nowSeconds]. */
    fun liveHosts(nowSeconds: Long): Set<String> =
        byAddress.values.filter { it.isLiveAt(nowSeconds) }.mapTo(mutableSetOf()) { it.hostPubkey }

    /**
     * Of [pubkeys], the ones not asked about within [RECHECK_AFTER_MS],
     * marked as asked at [nowMs].
     */
    fun takeDue(pubkeys: Set<String>, nowMs: Long): List<String> {
        val due = pubkeys.filter { key ->
            val at = askedAt[key]
            at == null || nowMs - at >= RECHECK_AFTER_MS
        }.sorted()
        for (key in due) askedAt[key] = nowMs
        return due
    }

    /** Another account has a different block list and follows; start over. */
    fun reset() {
        byAddress.clear()
        askedAt.clear()
    }

    private fun LiveStream.isLiveAt(nowSeconds: Long) = isPlayableLive && isOnAirAt(nowSeconds)

    companion object {
        /**
         * How long a "not live" answer for a pubkey stands before it is asked
         * again. Streams start at any time, so this is short.
         */
        const val RECHECK_AFTER_MS = 3 * 60 * 1000L
    }
}
