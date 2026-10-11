package com.nostrvault.data.model

import com.nostrvault.data.local.EngagementTracker

// ---------------------------------------------------------------------------
// Background accumulator (thread-safe event buffer)
// ---------------------------------------------------------------------------

class BackgroundAccumulator {
    private val lock = Any()

    val notes = mutableListOf<FeedNote>()
    val profiles = mutableListOf<String>()
    val reactionEvents = mutableListOf<EngagementTracker.ReactionEvent>()
    val zapEvents = mutableListOf<Pair<String, Long>>() // (targetId, amountSats)
    val repostTargets = mutableListOf<String>()
    val rawEventEntries = mutableListOf<Pair<String, String>>() // (id, json)
    var flushScheduled = false

    val seenEngagementIds = mutableSetOf<String>()

    var isInitialLoad = false
    var isGlobalMode = false

    val effectiveFlushIntervalMs: Long
        get() = when {
            isGlobalMode -> 50L
            isInitialLoad -> 200L
            else -> 500L
        }

    /** Add a content note to the buffer. */
    fun addNote(note: FeedNote) { synchronized(lock) { notes.add(note) } }

    /** Add a reaction engagement event. */
    fun addReaction(reaction: EngagementTracker.ReactionEvent) { synchronized(lock) { reactionEvents.add(reaction) } }

    /** Add a zap engagement event. */
    fun addZap(targetId: String, amountSats: Long) { synchronized(lock) { zapEvents.add(targetId to amountSats) } }

    data class Snapshot(
        val notes: List<FeedNote>,
        val profiles: List<String>,
        val reactions: List<EngagementTracker.ReactionEvent>,
        val zaps: List<Pair<String, Long>>,
        val repostTargets: List<String>,
        val rawEventEntries: List<Pair<String, String>>,
    )

    fun drain(): Snapshot {
        synchronized(lock) {
            val snap = Snapshot(
                notes = notes.toList(),
                profiles = profiles.toList(),
                reactions = reactionEvents.toList(),
                zaps = zapEvents.toList(),
                repostTargets = repostTargets.toList(),
                rawEventEntries = rawEventEntries.toList(),
            )
            notes.clear()
            profiles.clear()
            reactionEvents.clear()
            zapEvents.clear()
            repostTargets.clear()
            rawEventEntries.clear()
            flushScheduled = false

            // Cap dedup set
            if (seenEngagementIds.size > MAX_ENGAGEMENT_IDS) {
                val keep = seenEngagementIds.sortedDescending().take(MAX_ENGAGEMENT_IDS / 2)
                seenEngagementIds.clear()
                seenEngagementIds.addAll(keep)
            }
            return snap
        }
    }

    companion object {
        private const val MAX_ENGAGEMENT_IDS = 20_000
    }
}
