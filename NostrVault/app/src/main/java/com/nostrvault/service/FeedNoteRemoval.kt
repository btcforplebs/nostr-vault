package com.nostrvault.service

import com.nostrvault.data.model.FeedNote

/**
 * Every place a deleted note can still be read from. `removeNote` only
 * filtered the visible feed, so the "new posts" pill and the parent cache
 * could put the post back, and the thread screen kept a deleted parent or
 * reply on screen. iOS `FeedService.removeNote(id:)` clears all three.
 */
object FeedNoteRemoval {
    /** [notes] without the deleted note. Nothing else moves. */
    fun without(notes: List<FeedNote>, id: String): List<FeedNote> =
        notes.filter { it.id != id }

    /** [cache] without the deleted note, whatever key it was filed under. */
    fun without(cache: Map<String, FeedNote>, id: String): Map<String, FeedNote> =
        cache.filterValues { it.id != id }
}
