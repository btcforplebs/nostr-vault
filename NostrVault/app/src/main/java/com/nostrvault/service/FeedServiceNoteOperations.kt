package com.nostrvault.service

import com.nostrvault.data.model.*
import kotlinx.coroutines.*
import kotlinx.coroutines.flow.*
import kotlinx.serialization.json.*
import com.nostrvault.service.FeedService.Companion.MAX_FEED_NOTES

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
