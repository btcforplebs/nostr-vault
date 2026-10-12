package com.nostrvault.service

import android.util.Log
import com.nostrvault.data.model.FeedNote
import com.nostrvault.service.NostrService.Companion.TAG
import com.nostrvault.service.deleted.DeletedPost
import com.nostrvault.service.deleted.DeletedPostsStore
import kotlinx.coroutines.suspendCancellableCoroutine
import kotlin.coroutines.resume

    // ══════════════════════════════════════════════════════════════════
    // Recently Deleted: a copy of each post this device deletes, so it can
    // be posted again. See DeletedPost for why un-delete makes a new post.
    // Port of iOS NostrService+DeletedPosts.swift.
    // ══════════════════════════════════════════════════════════════════

    /**
     * A copy of your post [noteId], taken before its delete request is
     * signed. Looks in memory first, then asks this device's vault, which
     * still holds the post until the kind 5 reaches it. null for a post found
     * nowhere, not signed by the active account, or of a kind that gets no
     * copy ([DeletedPost.keepsCopy]).
     */
    internal suspend fun NostrService.copyBeforeDeleting(noteId: String): DeletedPost? {
        val owner = activeHexPubkey
        if (owner.isEmpty()) return null
        val event = events.firstOrNull { it.id == noteId } ?: fetchFromOwnVault(noteId) ?: return null
        if (event.id != noteId || event.pubkey != owner || event.sig.isEmpty()) return null
        if (!DeletedPost.keepsCopy(event.kind)) return null
        return DeletedPost(
            id = event.id, pubkey = event.pubkey, createdAt = event.createdAt, kind = event.kind,
            tags = event.tags, content = event.content, sig = event.sig,
            deletedAt = System.currentTimeMillis(),
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
     * Posts the saved copy again as a new event, stamped now. The copy is
     * dropped only once an outside relay accepts the new event. Returns false
     * if it was not posted (signing failed, the account changed so it would
     * go out under another name, or no relay took it); the copy is kept.
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
        val outcome = suspendCancellableCoroutine { cont ->
            postEvent(event) { if (cont.isActive) cont.resume(it) }
        }
        if (outcome != BroadcastTally.Outcome.ACCEPTED) return false
        feedService.emitOptimisticNote(
            FeedNote.fromEvent(event.id, event.pubkey, event.content, event.tags, event.createdAt, event.kind)
        )
        store.remove(post.id, post.pubkey)
        return true
    }
