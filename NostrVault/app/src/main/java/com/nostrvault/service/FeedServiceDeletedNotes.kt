package com.nostrvault.service

import com.nostrvault.data.local.DeletedNotesStore
import com.nostrvault.data.model.FeedNote
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.flow.update
import kotlinx.coroutines.launch

/**
 * Keeping deleted posts gone: your own kind-5 requests, from this device
 * or another, take their targets off the feed, the thread screen, the
 * snapshot a restart restores, and the root and quote fetches. See
 * [DeletedNotes] for the rules and [DeletedNotesStore] for what is
 * remembered. Twin: iOS `FeedService+DeletedNotes.swift`.
 */

private val FeedService.deletedNotesAccount: String get() = nostrService.activeHexPubkey

/** The active account's deleted ids. */
val FeedService.deletedNoteIds: Set<String>
    get() = DeletedNotesStore.shared.ids(deletedNotesAccount)

fun FeedService.isDeleted(id: String): Boolean =
    DeletedNotesStore.shared.contains(id, deletedNotesAccount)

/** Whether a row stays off screen: the deleted post, or a repost of it. */
fun FeedService.hidesDeleted(note: FeedNote): Boolean = DeletedNotes.hides(note, deletedNoteIds)

fun FeedService.withoutDeletedNotes(notes: List<FeedNote>): List<FeedNote> =
    DeletedNotes.visible(notes, deletedNoteIds)

/**
 * The feed relays' subscription for the owner's own kind-5 requests. The
 * local relay serves the ones your other devices sent once the vault has
 * imported them; the outbox relays serve them directly. No `since`: an
 * old request still counts.
 */
fun deleteRequestsFilter(owner: String): String =
    """{"kinds":[${DeletedNotes.REQUEST_KIND}],"authors":["$owner"],"limit":200}"""

/** A kind 5 from a feed subscription, on the relay's reader thread. */
fun FeedService.handleDeleteRequest(pubkey: String, tags: List<List<String>>) {
    val ids = DeletedNotes.targets(tags)
    if (ids.isEmpty()) return
    scope.launch(Dispatchers.Main.immediate) {
        if (!DeletedNotes.isOwnRequest(DeletedNotes.REQUEST_KIND, pubkey, deletedNotesAccount)) return@launch
        purgeDeletedNotes(ids)
    }
}

/**
 * Remembers [ids] as deleted for the active account and takes them, and
 * reposts of them, off every list and cache this service holds. Main thread.
 */
fun FeedService.purgeDeletedNotes(ids: Set<String>) {
    if (ids.isEmpty()) return
    DeletedNotesStore.shared.markDeleted(ids, deletedNotesAccount)
    _notes.value = DeletedNotes.visible(_notes.value, ids)
    _pendingNotes.value = DeletedNotes.visible(_pendingNotes.value, ids)
    _parentNotesCache.value = DeletedNotes.visible(_parentNotesCache.value, ids)
    _feedThreadReplies.value = DeletedNotes.visible(_feedThreadReplies.value, ids)
    // A quote or thread card waiting on one shows "unavailable" rather than
    // a skeleton, and never asks a relay for it.
    _unavailableNoteIds.update { it + ids }
    recomputeFilteredNotes()

    nostrService.events = nostrService.events.filterNot { it.id in ids }
    nostrService._eventUpdates.tryEmit(Unit)
}
