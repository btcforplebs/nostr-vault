package com.nostrvault.service

import android.util.Log
import com.nostrvault.data.local.DeletedNotesStore
import com.nostrvault.service.NostrService.Companion.TAG
import com.nostrvault.service.deleted.DeletedPost
import com.nostrvault.service.deleted.DeletedPostsStore
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.launch
import kotlinx.coroutines.withContext

/**
 * Deleting your own posts, one by id or every post linking a blob. Lives
 * outside `NostrService.kt`, which is over the file-size limit. iOS twin:
 * `NostrService+Moderation.swift`.
 */

/**
 * Publishes a NIP-09 deletion request (kind 5) for [noteId], then drops the
 * post from [NostrService.events] so your Posts and Media lists stop showing
 * it before the next reload. Signing failures leave the list alone, like
 * [deleteOwnEvents].
 */
fun NostrService.deleteNote(noteId: String) {
    scope.launch(Dispatchers.IO) {
        val copy = try {
            copyBeforeDeleting(noteId)
        } catch (e: Exception) {
            Log.w(TAG, "deleteNote: no copy for ${noteId.take(8)}: ${e.message}")
            null
        }
        val signed = try {
            signEventAsync(kind = 5, content = "", tags = NoteDeletion.requestTags(noteId))
        } catch (e: Exception) {
            Log.e(TAG, "deleteNote: not signed: ${e.message}")
            null
        } ?: return@launch
        DeletedPost.keptAfterSigning(copy, signed.pubkey)?.let { DeletedPostsStore.shared.save(it) }
        postEvent(signed)
        withContext(Dispatchers.Main) {
            events = NoteDeletion.without(events, noteId)
            _eventUpdates.tryEmit(Unit)
            DeletedNotesStore.shared.markDeleted(setOf(noteId), activeHexPubkey)
        }
    }
}

/**
 * Asks relays to delete your posts that link the blob [referencingBlob]
 * (one NIP-09 request naming them all), and drops them and their media
 * here so the feed and Media tab stop showing a file that is gone.
 * @return how many posts the request named, 0 if signing failed.
 */
suspend fun NostrService.deleteOwnEvents(referencingBlob: String): Int {
    val targets = ownEvents(referencingBlob)
    if (targets.isEmpty()) return 0
    val signed = try {
        signEventAsync(kind = 5, content = "", tags = BlobPostDeletion.deletionTags(targets))
    } catch (e: Exception) {
        Log.e(TAG, "deleteOwnEvents: not signed: ${e.message}")
        null
    } ?: return 0
    postEvent(signed)
    val ids = targets.mapTo(HashSet()) { it.id }
    val hash = referencingBlob.lowercase()
    val owner = activeHexPubkey
    withContext(Dispatchers.Main) {
        events = events.filterNot { it.id in ids }
        noteMedia = noteMedia.filterNot { it.pubkey == owner && it.url.lowercase().contains(hash) }
        _eventUpdates.tryEmit(Unit)
        DeletedNotesStore.shared.markDeleted(ids, owner)
    }
    return targets.size
}
