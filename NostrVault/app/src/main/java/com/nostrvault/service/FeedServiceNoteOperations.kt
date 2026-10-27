package com.nostrvault.service

import com.nostrvault.data.model.*
import kotlinx.coroutines.*
import kotlinx.coroutines.flow.*
import kotlinx.serialization.json.*
import com.nostrvault.service.FeedService.Companion.MAX_FEED_NOTES

/**
 * The feed's lookup by id and by effectiveEventId. Own ids first: a repost
 * files under its original's id too, and when it sat earlier in the list it
 * claimed that key, so every lookup of the original then fell back to a scan
 * of the whole feed on Main. Within each pass the first note wins.
 */
internal fun buildNoteIndex(notes: List<FeedNote>): Map<String, FeedNote> {
    val map = HashMap<String, FeedNote>(notes.size * 2)
    for (note in notes) map.putIfAbsent(note.id, note)
    for (note in notes) map.putIfAbsent(note.effectiveEventId, note)
    return map
}

/**
 * The note in the feed whose own id is [id], or null. [index] is the feed's
 * lookup by id and by effectiveEventId; own ids are filed before a repost's
 * effectiveEventId, so a hit under another id means no note has this one as
 * its own (iOS #302 matches on the note's own id). [notes] is unused: the
 * fallback scan of the whole feed ran on Main for every repost in view.
 */
internal fun feedNoteWithOwnId(index: Map<String, FeedNote>, @Suppress("UNUSED_PARAMETER") notes: List<FeedNote>, id: String): FeedNote? {
    val hit = index[id] ?: return null
    return if (hit.id == id) hit else null
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

    /**
     * How many staged new posts the current feed would actually show. The raw
     * pending list is unfiltered, and in Global with the Web of Trust on most
     * of it is filtered out: counting it raw put "50 new posts" on a pill that
     * revealed nothing.
     */
    internal fun FeedService.visiblePendingCountImpl(pending: List<FeedNote>): Int {
        if (pending.isEmpty()) return 0
        val config = configStore.config.value
        val blockedPubkeys = config.blockedForActiveAccount()
            .mapNotNull { nostrService.npubToHex(it) }.toSet()
        return if (_feedMode.value == FeedMode.MEDIA) {
            feedFilterEngine.filterMediaNotes(
                notes = pending,
                blocked = blockedPubkeys,
                wotPubkeys = _wotPubkeys.value,
                isGlobalMedia = _mediaFeedMode.value == MediaFeedMode.GLOBAL,
                globalRequiresTrust = !config.globalShowsEveryone,
                authorOf = ::authorOf,
            ).size
        } else {
            filterForCurrentFeed(pending, config, blockedPubkeys).size
        }
    }

    internal fun FeedService.applyPendingNotesImpl() {
        val pending = _pendingNotes.value
        if (pending.isEmpty()) return

        _notes.value = (pending + _notes.value)
            .distinctBy { it.id }
            .sortedByDescending { it.createdAt }
            .take(MAX_FEED_NOTES)
        _pendingNotes.value = emptyList()
        _newNoteCount.value = 0
        recomputeFilteredNotes()
    }
