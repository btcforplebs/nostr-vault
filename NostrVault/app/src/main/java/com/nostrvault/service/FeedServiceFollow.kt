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
                if (rollback != null && _followedPubkeys.value == pubkeys) {
                    if (refusedAt != null) refusedContactListCreatedAt = refusedAt
                    _followedPubkeys.value = rollback
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
