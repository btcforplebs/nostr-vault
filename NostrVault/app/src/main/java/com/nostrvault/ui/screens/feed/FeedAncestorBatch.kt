package com.nostrvault.ui.screens.feed

import com.nostrvault.data.model.FeedNote
import kotlinx.coroutines.delay
import kotlinx.coroutines.flow.Flow
import kotlinx.coroutines.flow.conflate
import kotlinx.coroutines.flow.transform

/**
 * The threaded feed's missing ancestors (parents and NIP-10 roots), worked
 * out once per note list rather than on every fetched parent. Pure, so the
 * rule is pinned by tests.
 */
internal object FeedAncestorBatch {
    /** Ancestors are fetched one by one while scrolling: regroup at most this often. */
    const val WINDOW_MS = 150L

    /** Every parent and thread root [notes] point at. */
    fun gaps(notes: List<FeedNote>): Set<String> = buildSet {
        for (note in notes) {
            note.parentEventId?.let { add(it) }
            add(note.threadRootId)
        }
    }

    /**
     * What a row fetches as soon as it is in the list: its parent, a bare
     * repost's original, and a NIP-22 comment's `E` root, so its hint is
     * asked before the thread card needs it (iOS FeedService+NoteBatching;
     * Tidy 2a057690: a Mostr-bridged root lived only on its `E` hint).
     */
    fun rowFetchIds(note: FeedNote): List<String> = listOfNotNull(
        note.parentEventId,
        note.repostedEventId?.takeIf { note.isBareRepost },
        com.nostrvault.data.model.NIP10Thread.rootEventId(note.kind, note.tags)
            ?.takeIf { note.kind == com.nostrvault.data.model.NIP10Thread.COMMENT_KIND && it != note.parentEventId },
    )

    /** The [gaps] the parent cache already holds. */
    fun resolved(gaps: Set<String>, cache: Map<String, *>): Set<String> =
        if (cache.isEmpty()) emptySet() else gaps.filterTo(HashSet()) { it in cache }
}

/**
 * The first value at once, then at most one per [windowMs]: the newest one
 * that arrived in the window, so a burst of arrivals lands as one regroup and
 * the last value is never dropped.
 */
internal fun <T> Flow<T>.batched(windowMs: Long): Flow<T> =
    conflate().transform { emit(it); delay(windowMs) }
