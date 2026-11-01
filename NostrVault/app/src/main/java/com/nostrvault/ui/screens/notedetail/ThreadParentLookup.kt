package com.nostrvault.ui.screens

import com.nostrvault.data.model.FeedNote
import com.nostrvault.service.FeedService
import com.nostrvault.service.retryMissingNote
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.flow.combine
import kotlinx.coroutines.flow.first
import kotlinx.coroutines.launch
import kotlinx.coroutines.withTimeoutOrNull

/**
 * The thread page's own fetch asks only your relays. A parent that lives
 * elsewhere is handed to the feed's note lookup, which also asks the relay
 * the reply names in its `e` tag and the parent author's write relays, then
 * the last-stop relays. Each id is asked once per thread page.
 */
internal class ThreadParentLookup(
    private val feedService: FeedService,
    private val scope: CoroutineScope,
) {
    private val asked = HashSet<String>()
    private val pending = java.util.Collections.synchronizedSet(HashSet<String>())

    /** A lookup is still waiting on relays. */
    val isRunning: Boolean get() = pending.isNotEmpty()

    /**
     * Look [id] up; [onDone] gets the note, or null once every relay has been
     * asked. Returns false (and does nothing) when [id] was already asked.
     */
    fun ask(id: String, onDone: (FeedNote?) -> Unit): Boolean {
        synchronized(asked) { if (!asked.add(id)) return false }
        pending.add(id)
        feedService.retryMissingNote(id)
        scope.launch {
            val outcome = withTimeoutOrNull(LOOKUP_TIMEOUT_MS) {
                combine(feedService.parentNotesCache, feedService.unavailableNoteIds) { cache, unavailable ->
                    cache[id] to (id in unavailable)
                }.first { (note, givenUp) -> note != null || givenUp }
            }
            pending.remove(id)
            onDone(outcome?.first)
        }
        return true
    }

    companion object {
        const val LOOKUP_TIMEOUT_MS = 20_000L

        /** The parent the chain still lacks: the top note's parent, or null when the chain reaches a root. */
        fun missingParentId(note: FeedNote, chain: List<FeedNote>): String? =
            (chain.firstOrNull() ?: note).parentEventId
    }
}
