package com.nostrvault.data.model

import java.util.Date

/**
 * Keeps the threaded feed's card order still while the reader is on it.
 *
 * [FeedThreadGrouping.build] sorts by latest activity, so a reply (your own,
 * or anyone's arriving live) lifted its card to the top, and the keyed list
 * followed it there: you replied, and were thrown back to the top of the feed.
 * Here each card keeps the sort key it had when it was first shown, so its
 * replies show inside it, in place. Cards not seen before slot in by their
 * real activity (a fresh page of older posts lands at the bottom, a newly
 * active conversation above). [resort] lets the next pass sort for real: the
 * pill, pull to refresh, the Feed tab, a feed/layout/account switch and every
 * return to the app call it. Research: RESEARCH/NV_THREADED_FEED_REPLY_ORDER.md
 * option B. iOS twin to come: `FeedThreadOrderFreeze.swift`.
 */
class FeedThreadOrderFreeze {
    private val lock = Any()
    private var keys: Map<String, Date> = emptyMap()

    /** Sort keys are dropped; the next [apply] takes the order as built. */
    fun resort() = synchronized(lock) { keys = emptyMap() }

    /** [threads] as built (newest activity first), held in the order already on screen. */
    fun apply(threads: List<FeedThread>): List<FeedThread> = synchronized(lock) {
        val ordered = order(threads, keys)
        keys = ordered.associate { it.rootId to (keys[it.rootId] ?: it.latestActivity) }
        ordered
    }

    companion object {
        /**
         * Sorts [threads] by their frozen key from [keys], or by their own
         * latest activity when they have none. Ties keep the order given.
         */
        fun order(threads: List<FeedThread>, keys: Map<String, Date>): List<FeedThread> {
            if (keys.isEmpty()) return threads
            return threads.withIndex()
                .sortedWith(
                    compareByDescending<IndexedValue<FeedThread>> { keys[it.value.rootId] ?: it.value.latestActivity }
                        .thenBy { it.index },
                )
                .map { it.value }
        }
    }
}
