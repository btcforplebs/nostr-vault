package com.nostrvault.service

import android.util.Log
import com.nostrvault.data.model.*
import kotlinx.coroutines.*
import kotlinx.coroutines.flow.*
import kotlinx.serialization.json.*
import com.nostrvault.service.FeedService.Companion.TAG

    /**
     * [rollback]: the list before this edit. If signing fails or every relay
     * refuses the event, and nothing has changed the list since, it is put
     * back so the screen never shows a follow that was not published; then
     * [onFailed] runs, on the main thread.
     */
    internal fun FeedService.publishContactList(
        pubkeys: List<String>,
        rollback: List<String>? = null,
        onFailed: (() -> Unit)? = null,
    ) {
        // The key has a list now; from here on its load must find it.
        FreshAccountKeys.clear(appContext, nostrService.activeHexPubkey)
        val tags = pubkeys.map { listOf("p", it) }
        val fail: (refusedAt: Long?) -> Unit = { refusedAt ->
            scope.launch(Dispatchers.Main.immediate) {
                val restore = followRollback(_followedPubkeys.value, pubkeys, rollback)
                if (restore != null) {
                    if (refusedAt != null) refusedContactListCreatedAt = refusedAt
                    _followedPubkeys.value = restore
                    recomputeFilteredNotes()
                    resubscribePrimaryToConnected()
                }
                onFailed?.invoke()
            }
        }
        // Bump the local-edit guard synchronously to "now" so an immediate contact
        // refresh (firing before the async sign/post below completes) can't accept a
        // stale relay copy and drop the edit we're about to publish.
        val accountKey = configStore.config.value.activeAccountNpub
            ?: configStore.config.value.ownerNpub
        ownContactListAccountKey = accountKey
        ownContactListCreatedAt = maxOf(ownContactListCreatedAt, System.currentTimeMillis() / 1000L)
        scope.launch(Dispatchers.IO) {
            val event = runCatching { nostrService.signEventAsync(
                kind = 3,
                content = contactListContent,
                tags = tags,
            ) }.onFailure { Log.e(TAG, "contact list not signed: ${it.message}") }.getOrNull()
            if (event == null) fail(null)
            event?.let {
                // Record the published list's created_at + a durable backup so a
                // later relay fetch returning an older copy can't clobber this edit.
                ownContactListCreatedAt = maxOf(ownContactListCreatedAt, it.createdAt)
                followingBackupService.maybeCreateSnapshot(
                    pubkeys = pubkeys,
                    pTags = tags,
                    contactListContent = contactListContent,
                    contactListCreatedAt = it.createdAt,
                    forAccountKey = accountKey,
                )
                nostrService.postEvent(it) { outcome ->
                    if (outcome == BroadcastTally.Outcome.REFUSED) fail(it.createdAt)
                }
            }
        }
    }

    /** Best display name for a pubkey (profile name or truncated hex). */
    internal fun FeedService.profileDisplayName(pubkey: String): String =
        nostrService.profiles.value[pubkey]?.bestName ?: "${pubkey.take(8)}..."

    /**
     * The list to put back after a refused publish: [rollback], unless there
     * is none or the list changed since ([current] is no longer what was
     * [published]), when a newer edit owns it. Null leaves it alone.
     */
    internal fun followRollback(current: List<String>, published: List<String>, rollback: List<String>?): List<String>? =
        rollback?.takeIf { current == published }

    /**
     * The pill when a follow or unfollow didn't go out and the button snapped
     * back: says which, and that another tap may work. Never silent.
     */
    internal fun followFailedMessage(follow: Boolean): String =
        if (follow) "Couldn't follow, try again" else "Couldn't unfollow, try again"
