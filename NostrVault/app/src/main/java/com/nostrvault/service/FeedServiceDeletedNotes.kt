package com.nostrvault.service

import com.nostrvault.data.local.DeletedNotesStore
import com.nostrvault.data.model.FeedNote
import com.nostrvault.relay.HavenBridge
import kotlinx.serialization.json.JsonObject
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.Job
import kotlinx.coroutines.delay
import kotlinx.coroutines.flow.update
import kotlinx.coroutines.launch
import java.util.Collections
import java.util.WeakHashMap
import kotlin.coroutines.CoroutineContext

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
 * The deleted ids among [ids], marked unavailable. A deleted post is never
 * asked for again: a relay that ignored the request would hand it back as a
 * thread root or quote. The card shows "unavailable" instead of a skeleton.
 */
fun FeedService.markDeletedUnavailable(ids: List<String>): List<String> {
    val deleted = ids.filter { isDeleted(it) }
    if (deleted.isNotEmpty()) _unavailableNoteIds.update { it + deleted }
    return deleted
}

/**
 * The feed relays' subscription for the owner's own kind-5 requests. The
 * local relay serves the ones your other devices sent once the vault has
 * imported them; the outbox relays serve them directly. No `since`: an
 * old request still counts.
 */
fun deleteRequestsFilter(owner: String): String =
    """{"kinds":[${DeletedNotes.REQUEST_KIND}],"authors":["$owner"],"limit":200}"""

/**
 * A kind 5 from a feed subscription, as the relay sent it, on the relay's
 * reader thread. Nothing is remembered until the event's signature checks
 * out: a relay could otherwise hide any post under your name. Ids already
 * deleted are dropped before that check, the check runs off Main, and the
 * requests that pass are purged together ([DeleteRequestBatcher]).
 */
fun FeedService.handleDeleteRequest(event: JsonObject, tags: List<List<String>>) {
    val ids = DeletedNotes.targets(tags)
    if (ids.isEmpty()) return
    deleteRequestBatcher.submit(event, ids, deletedNotesAccount)
}

/** One batcher per service; this file adds no field to [FeedService]. */
private val deleteRequestBatchers =
    Collections.synchronizedMap(WeakHashMap<FeedService, DeleteRequestBatcher>())

private val FeedService.deleteRequestBatcher: DeleteRequestBatcher
    get() = synchronized(deleteRequestBatchers) {
        deleteRequestBatchers.getOrPut(this) {
            DeleteRequestBatcher(
                scope = scope,
                verifyContext = Dispatchers.Default,
                purgeContext = Dispatchers.Main.immediate,
                account = { deletedNotesAccount },
                isKnown = { id, account -> DeletedNotesStore.shared.contains(id, account) },
                verify = { event, account -> DeletedNotes.isOwnSignedRequest(event, account, HavenBridge::verifyEvent) },
                purge = { ids -> purgeDeletedNotes(ids) },
            )
        }
    }

/**
 * Turns a burst of kind 5s into one purge. The deletions request has no
 * `since`, so every resubscribe hands back up to 200 of them, mostly ones
 * already applied: those cost a set lookup, not a signature check. The rest
 * are verified on [verifyContext]; the ids that pass wait [BATCH_MS] on
 * [purgeContext] for the rest of the burst, then go to [purge] in one call,
 * so the lists and the feed are rebuilt once, not once per event.
 *
 * Ids are held under the account they were checked for. One that is no
 * longer active by the time the batch runs is dropped; its own subscription
 * sends the request again.
 */
internal class DeleteRequestBatcher(
    private val scope: CoroutineScope,
    private val verifyContext: CoroutineContext,
    private val purgeContext: CoroutineContext,
    private val account: () -> String,
    private val isKnown: (id: String, account: String) -> Boolean,
    private val verify: (event: JsonObject, account: String) -> Boolean,
    private val purge: (Set<String>) -> Unit,
) {
    private val lock = Any()
    private val pending = HashMap<String, MutableSet<String>>()
    private var flush: Job? = null

    fun submit(event: JsonObject, ids: Set<String>, owner: String) {
        val fresh = ids.filterNotTo(HashSet()) { isKnown(it, owner) }
        if (fresh.isEmpty()) return
        scope.launch(verifyContext) {
            if (!verify(event, owner)) return@launch
            synchronized(lock) {
                pending.getOrPut(owner) { HashSet() } += fresh
                if (flush == null) {
                    flush = scope.launch(purgeContext) {
                        delay(BATCH_MS)
                        drain()
                    }
                }
            }
        }
    }

    private fun drain() {
        val active = account()
        val ids = synchronized(lock) {
            flush = null
            val batch = pending[active].orEmpty().toSet()
            pending.clear()
            batch
        }
        // Another path may have applied some while the batch waited.
        val fresh = ids.filterNotTo(HashSet()) { isKnown(it, active) }
        if (fresh.isNotEmpty()) purge(fresh)
    }

    companion object {
        /** How long the first verified request waits for the rest of its burst. */
        const val BATCH_MS = 50L
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
