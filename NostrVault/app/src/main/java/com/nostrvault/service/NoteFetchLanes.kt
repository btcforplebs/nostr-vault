package com.nostrvault.service

import kotlinx.coroutines.Job

/**
 * The ids waiting for the next missing-note lookup, in two lanes.
 *
 * The feed asks for every parent and quote its loaded notes point at, which
 * for a few thousand notes is close to a thousand ids (measured 2026-11-11 on
 * a 2,774-note Following feed: 900 parents, 61 quotes). They all went into one
 * queue, in the order the feed listed them, so the quote in the row on screen
 * was sent in the last batch and its answer was read after everyone else's.
 * iOS asks per row as it nears the screen (`FeedPrefetcher.warm`), which is
 * why a quote is there by the time the row is.
 *
 * [Lane.NEAR_SCREEN] is that: the rows on screen and the next few. It is sent
 * after a short wait and before the rest. An id asked for near the screen
 * while it sits in [Lane.REST] moves over.
 *
 * Not thread-safe: callers hold this object's monitor for every call and for
 * reads and writes of [jobs].
 */
internal class NoteFetchLanes {
    enum class Lane(val delayMs: Long) {
        /** Long enough to gather the rows a flick brings in, short enough not to be seen. */
        NEAR_SCREEN(500L),
        /** One lookup per relay for a whole scroll's worth, instead of one every 300 ms. */
        REST(FeedService.NOTE_FETCH_BATCH_DELAY_MS),
    }

    private val near = LinkedHashSet<String>()
    private val rest = LinkedHashSet<String>()

    /** The flush job of each lane while it has ids to send. */
    val jobs = HashMap<Lane, Job>()

    fun add(ids: Collection<String>, lane: Lane) {
        when (lane) {
            Lane.NEAR_SCREEN -> {
                rest.removeAll(ids.toSet())
                near.addAll(ids)
            }
            Lane.REST -> ids.filterTo(rest) { it !in near }
        }
    }

    /** Takes everything waiting in [lane], oldest first. */
    fun drain(lane: Lane): List<String> {
        val queue = if (lane == Lane.NEAR_SCREEN) near else rest
        val out = queue.toList()
        queue.clear()
        return out
    }

    companion object {
        /**
         * How long the first pass has before the relays of last resort are
         * asked as well (iOS: 3.5 s). The second pass used to wait for every
         * relay of the first to finish, so one relay that never answered held
         * it for the whole 8 s window.
         */
        const val SECOND_PASS_AFTER_MS = 3_500L
    }
}

/**
 * How the cache of fetched parents, roots, repost originals and quotes is
 * kept in bounds. iOS `handleParentNoteFetch`: keep everything a loaded note
 * still points at, and look again only after another [STEP] have arrived.
 *
 * It used to keep the 400 most recently *written* notes. A quoted note is
 * older than the note quoting it, often by weeks, so in a feed pointing at
 * more than 500 notes the quotes were the first thing dropped: the row fell
 * back to "Loading quoted note..." and the note was fetched again.
 */
internal object ReferencedNoteCache {
    const val FLOOR = 500
    const val STEP = 250

    /** [cache] without what no loaded note points at; [keep] (the note just fetched) always stays. */
    fun <V> trimmed(cache: Map<String, V>, referencedIds: Set<String>, keep: String): Map<String, V> =
        cache.filter { it.key in referencedIds || it.key == keep }

    /** The size at which to trim next, given the size the last trim left. */
    fun nextTrimAt(sizeAfterTrim: Int): Int = maxOf(FLOOR, sizeAfterTrim + STEP)
}
