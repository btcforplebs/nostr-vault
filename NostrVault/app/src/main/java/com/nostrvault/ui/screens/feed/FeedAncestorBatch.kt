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
