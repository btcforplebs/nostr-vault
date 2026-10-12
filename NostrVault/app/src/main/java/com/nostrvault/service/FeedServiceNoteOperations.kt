package com.nostrvault.service

import com.nostrvault.data.model.*
import kotlinx.coroutines.*
import kotlinx.coroutines.flow.*
import kotlinx.serialization.json.*

/**
 * The note in the feed whose own id is [id], or null. [index] is the feed's
 * lookup by id and by effectiveEventId; a repost is filed under its original's
 * id too, and a newer repost claims that key before the original, so a miss
 * there falls back to [notes] (iOS #302 matches on the note's own id).
 */
internal fun feedNoteWithOwnId(index: Map<String, FeedNote>, notes: List<FeedNote>, id: String): FeedNote? {
    val hit = index[id] ?: return null
    return if (hit.id == id) hit else notes.firstOrNull { it.id == id }
}

/**
 * Takes the note out of the feed, the "new posts" pill and the parent cache,
 * so nothing puts a deleted post back. iOS twin: `FeedService+NoteOperations.swift`.
 */
fun FeedService.removeNote(id: String) {
    _notes.value = FeedNoteRemoval.without(_notes.value, id)
    _pendingNotes.value = FeedNoteRemoval.without(_pendingNotes.value, id)
    _parentNotesCache.value = FeedNoteRemoval.without(_parentNotesCache.value, id)
    recomputeFilteredNotes()
}
