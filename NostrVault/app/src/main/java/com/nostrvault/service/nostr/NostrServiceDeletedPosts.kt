package com.nostrvault.service

import android.util.Log
import com.nostrvault.data.model.FeedNote
import com.nostrvault.service.NostrService.Companion.TAG
import com.nostrvault.service.deleted.DeletedPost
import com.nostrvault.service.deleted.DeletedPostsStore
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.launch

    // ══════════════════════════════════════════════════════════════════
    // Recently Deleted: a copy of each post this device deletes, so it can
    // be posted again. See DeletedPost for why un-delete makes a new post.
    // Port of iOS NostrService+DeletedPosts.swift.
    // ══════════════════════════════════════════════════════════════════

    /** Saves a copy of your post [noteId], then sends its NIP-09 delete request. */
    fun NostrService.deleteKeepingCopy(noteId: String, store: DeletedPostsStore) {
        scope.launch(Dispatchers.IO) {
            try {
                saveCopyBeforeDeleting(noteId, store)
            } catch (e: Exception) {
                Log.w(TAG, "deleteKeepingCopy: no copy saved for ${noteId.take(8)}: ${e.message}")
            }
            signAndPost(kind = 5, content = "", tags = listOf(listOf("e", noteId)))
        }
    }

    /**
     * Saves a copy of your post [noteId] before its delete request goes out.
     * Looks in memory first, then asks this device's vault, which still holds
     * the post until the kind 5 reaches it. A post found nowhere, or not
     * signed by the active account, is not saved; the delete still goes ahead.
     */
    internal suspend fun NostrService.saveCopyBeforeDeleting(noteId: String, store: DeletedPostsStore) {
        val owner = activeHexPubkey
        if (owner.isEmpty()) return
        val event = events.firstOrNull { it.id == noteId } ?: fetchFromOwnVault(noteId) ?: return
        if (event.id != noteId || event.pubkey != owner || event.sig.isEmpty()) return
        store.save(
            DeletedPost(
                id = event.id, pubkey = event.pubkey, createdAt = event.createdAt, kind = event.kind,
                tags = event.tags, content = event.content, sig = event.sig,
                deletedAt = System.currentTimeMillis(),
            )
        )
    }

    /** One `ids` query to this device's vault (the relay root holds your own posts). */
    private suspend fun NostrService.fetchFromOwnVault(id: String): NostrEvent? {
        val url = configStore.config.value.nostrURL ?: return null
        return queryRawEvents(listOf("""{"ids":["$id"],"limit":1}"""), listOf(url), timeoutMs = 3_000L)
            .firstNotNullOfOrNull { parseSignedEvent(it.toString()) }
            ?.takeIf { it.id == id }
    }

    /**
     * Posts the saved copy again as a new event, stamped now, then drops the
     * copy. Returns false if it was not posted (signing failed, or the
     * account changed so it would go out under another name).
     */
    suspend fun NostrService.undelete(post: DeletedPost, store: DeletedPostsStore, feedService: FeedService): Boolean {
        if (post.pubkey != activeHexPubkey) return false
        val lock = lockPostingAccount()
        val draft = post.republishDraft()
        val event = try {
            signEventAsync(kind = draft.kind, content = draft.content, tags = draft.tags, lockedTo = lock)
                ?.also { requireStillPostingAs(lock, it.pubkey) }
        } catch (e: Exception) {
            Log.w(TAG, "undelete: ${post.id.take(8)} not signed: ${e.message}")
            null
        } ?: return false
        if (event.pubkey != post.pubkey) return false
        postEvent(event)
        feedService.emitOptimisticNote(
            FeedNote.fromEvent(event.id, event.pubkey, event.content, event.tags, event.createdAt, event.kind)
        )
        store.remove(post.id, post.pubkey)
        return true
    }
