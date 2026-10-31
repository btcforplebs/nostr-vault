package com.nostrvault.service

import android.util.Log
import com.nostrvault.data.model.*
import kotlinx.coroutines.*
import kotlinx.coroutines.flow.*
import kotlinx.coroutines.sync.withLock
import kotlinx.serialization.json.*
import com.nostrvault.service.FeedService.Companion.TAG
import com.nostrvault.ui.notification.FollowKind

    /**
     * Signs [edit] onto the newest kind 3 (Logen 2026-10-31: never overwrite
     * a user's list). Right before signing it fetches the newest copy from
     * the relays and edits that, not the list read at launch: a follow made in
     * another app since is kept. When the relays don't answer, nothing is
     * signed (one "none" is not "you have none", see [ContactManager.saveBase]).
     *
     * [shown]: the list the screen shows for this edit. [rollback]: the list
     * before it. If the relays don't answer, signing fails, or every relay
     * refuses the event, and nothing has changed the list since, [rollback]
     * is put back so the screen never shows a follow that was not published;
     * then [onFailed] runs, on the main thread.
     */
    internal fun FeedService.publishContactList(
        shown: List<String>,
        edit: ContactManager.FollowEdit,
        rollback: List<String>? = null,
        onFailed: (() -> Unit)? = null,
    ) {
        // Discovery's follows-of-follows tally is an hour-long cache of the
        // old list: after an unfollow it kept everyone that follow brought
        // in. The next Discovery visit counts again. (The relay's web reloads
        // itself: it rebuilds on a new list and the FileObserver re-reads it.)
        lastExtendedNetworkLoadTime = 0L
        val owner = nostrService.activeHexPubkey
        // A key set up on this device has no list anywhere yet.
        val freshKey = FreshAccountKeys.isFresh(appContext, owner)
        // Signed as the account this list belongs to: a switch while a signer
        // prompt is open must not put A's follows under B's key.
        val lock = nostrService.lockPostingAccount()
        val fail: (refusedAt: Long?) -> Unit = { refusedAt ->
            scope.launch(Dispatchers.Main.immediate) {
                val restore = followRollback(_followedPubkeys.value, shown, rollback)
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
        val config = configStore.config.value
        val accountKey = config.activeAccountNpub ?: config.ownerNpub
        ownContactListAccountKey = accountKey
        ownContactListCreatedAt = maxOf(ownContactListCreatedAt, System.currentTimeMillis() / 1000L)
        val alsoAsk = (config.inboxRelays.orEmpty() + config.readRelays.take(3)).distinct()
        contactEditsInFlight.incrementAndGet()
        scope.launch(Dispatchers.IO) {
            var last = false
            // One at a time, each in a later second than the newest list
            // signed or loaded: two in one second tie, and relays keep the
            // lower id, dropping the other's follows.
            val saved = try {
                contactListPublishMutex.withLock {
                    val lookup = runCatching { nostrService.lookupNewestReplaceable(3, owner, alsoAsk) }
                        .onFailure { if (it is CancellationException) throw it }
                        .getOrNull()
                    val fetched = lookup?.event?.let { ContactManager.ListCopy(owner, it.tags, it.content, it.createdAt) }
                    val base = ContactManager.saveBase(owner, fetched, lookup?.confirmedNone == true, freshKey, knownContactList)
                    if (base == null) {
                        Log.w(TAG, "contact list not signed: relays didn't answer (${lookup?.answered ?: 0}/${lookup?.asked ?: 0})")
                        return@withLock null
                    }
                    knownContactList = base
                    lastContactListCreatedAt.updateAndGet { maxOf(it, base.createdAt) }
                    val basePubkeys = contactManager.parseContactList(base.tags).pubkeys
                    val pubkeys = edit.applyTo(basePubkeys)
                    // Already so on the newest copy (done in another app): nothing to sign.
                    if (pubkeys == basePubkeys) return@withLock base
                    val tags = ContactManager.contactListTags(pubkeys, base.tags)
                    delay(ContactManager.followListSignDelayMs(System.currentTimeMillis(), lastContactListCreatedAt.get()))
                    val event = runCatching { nostrService.signEventAsync(
                        kind = 3,
                        content = base.content,
                        tags = tags,
                        lockedTo = lock,
                    ) }.onFailure { Log.e(TAG, "contact list not signed: ${it.message}") }
                        .getOrElse { e ->
                            // The list is the previous account's: nothing to roll back here.
                            if (e is PostingAccount.AccountChangedException) return@launch
                            null
                        } ?: return@withLock null
                    lastContactListCreatedAt.updateAndGet { maxOf(it, event.createdAt) }
                    // The key has a list now; from here on its load must find it.
                    FreshAccountKeys.clear(appContext, owner)
                    ContactManager.ListCopy(owner, tags, base.content, event.createdAt).also {
                        knownContactList = it
                        // Record the published list's created_at + a durable backup so a
                        // later relay fetch returning an older copy can't clobber this edit.
                        ownContactListCreatedAt = maxOf(ownContactListCreatedAt, event.createdAt)
                        followingBackupService.maybeCreateSnapshot(
                            pubkeys = pubkeys,
                            pTags = tags,
                            contactListContent = base.content,
                            contactListCreatedAt = event.createdAt,
                            forAccountKey = accountKey,
                        )
                        nostrService.postEvent(event) { outcome ->
                            if (outcome == BroadcastTally.Outcome.REFUSED) fail(event.createdAt)
                        }
                    }
                }
            } finally {
                last = contactEditsInFlight.decrementAndGet() == 0
            }
            if (saved == null) {
                fail(null)
                return@launch
            }
            // The list as saved: the newest copy with this edit. Shown once no other edit is still on its way.
            val pubkeys = contactManager.parseContactList(saved.tags).pubkeys
            withContext(Dispatchers.Main.immediate) {
                contactListTags = saved.tags
                contactListContent = saved.content
                if (last && _followedPubkeys.value != pubkeys && nostrService.activeHexPubkey == owner) {
                    _followedPubkeys.value = pubkeys
                    recomputeFilteredNotes()
                    resubscribePrimaryToConnected()
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

    /**
     * A read-only account (no key here, no outside signer) can't sign a follow
     * list, and "try again" never helps: say so and stop before signing.
     */
    internal fun FeedService.refuseIfReadOnly(pubkey: String, follow: Boolean): Boolean {
        if (!nostrService.isReadOnlyAccount()) return false
        notificationManager.showFollow(profileDisplayName(pubkey), FollowKind.FAILED(readOnlyFollowMessage(follow)), pubkey = pubkey)
        return true
    }

    internal fun readOnlyFollowMessage(follow: Boolean): String =
        "This account is read-only. Add its key to ${if (follow) "follow" else "unfollow"}."

    /** [undo], when given, is offered on the "Followed" pill. */
    internal fun FeedService.followUserImpl(pubkey: String, undo: (() -> Unit)? = null): Result<Unit> {
        if (refuseIfReadOnly(pubkey, follow = true)) return Result.failure(FollowActionError.ReadOnly)
        if (!_hasAttemptedContactLoad.value || _isLoadingContacts.value) {
            queueFollowAction(pubkey, follow = true)
            return Result.failure(FollowActionError.ContactsNotLoaded)
        }
        val displayName = profileDisplayName(pubkey)
        val currentPTags = _followedPubkeys.value.map { listOf("p", it) }
        val result = contactManager.prepareFollow(
            pubkey = pubkey,
            currentPTags = currentPTags,
            currentPubkeys = _followedPubkeys.value,
            hasAttemptedLoad = _hasAttemptedContactLoad.value,
            isLoading = _isLoadingContacts.value,
            listConfirmed = contactListConfirmed,
        )
        return result.fold(
            onSuccess = { followResult ->
                val previous = _followedPubkeys.value
                _followedPubkeys.value = followResult.pubkeys
                publishContactList(followResult.pubkeys, ContactManager.FollowEdit(add = listOf(pubkey)), rollback = previous) {
                    notificationManager.showFollow(displayName, FollowKind.FAILED(followFailedMessage(follow = true)))
                }
                // Re-filter so already-loaded notes from the newly-followed author
                // surface immediately in the Following feed.
                recomputeFilteredNotes()
                // Re-issue the live primary REQ so the new follow's FUTURE notes
                // stream in without waiting for a full refresh.
                resubscribePrimaryToConnected()
                notificationManager.showFollow(displayName, FollowKind.FOLLOWED, undo, pubkey = pubkey)
                Result.success(Unit)
            },
            onFailure = {
                if (it is ContactManager.FollowActionError.ListUnavailable) {
                    // Kept queued and retried; never published against an unknown list.
                    queueFollowAction(pubkey, follow = true)
                    return Result.failure(it)
                }
                // A tap made while the list read empty: it was already done (iOS
                // resolves .alreadyFollowing as followed).
                val kind = if (it is ContactManager.FollowActionError.AlreadyFollowing) FollowKind.FOLLOWED
                else FollowKind.FAILED(it.message ?: "Failed")
                notificationManager.showFollow(displayName, kind, pubkey = pubkey)
                Result.failure(it)
            },
        )
    }

    /** [undo], when given, is offered on the "Unfollowed" pill. */
    internal fun FeedService.unfollowUserImpl(pubkey: String, undo: (() -> Unit)? = null): Result<Unit> {
        if (refuseIfReadOnly(pubkey, follow = false)) return Result.failure(FollowActionError.ReadOnly)
        if (!_hasAttemptedContactLoad.value || _isLoadingContacts.value) {
            queueFollowAction(pubkey, follow = false)
            return Result.failure(FollowActionError.ContactsNotLoaded)
        }
        val displayName = profileDisplayName(pubkey)
        val currentPTags = _followedPubkeys.value.map { listOf("p", it) }
        val result = contactManager.prepareUnfollow(
            pubkey = pubkey,
            activeAccountHex = nostrService.activeHexPubkey,
            currentPTags = currentPTags,
            currentPubkeys = _followedPubkeys.value,
            hasAttemptedLoad = _hasAttemptedContactLoad.value,
            isLoading = _isLoadingContacts.value,
            listConfirmed = contactListConfirmed,
        )
        return result.fold(
            // One deliberate unfollow from a list that loaded is always allowed,
            // even to 0: prepareUnfollow already refuses a list that didn't load.
            onSuccess = { followResult ->
                val previous = _followedPubkeys.value
                _followedPubkeys.value = followResult.pubkeys
                publishContactList(followResult.pubkeys, ContactManager.FollowEdit(remove = listOf(pubkey)), rollback = previous) {
                    notificationManager.showFollow(displayName, FollowKind.FAILED(followFailedMessage(follow = false)))
                }
                // Re-filter so the unfollowed author's notes disappear from the
                // Following feed immediately (the filter excludes non-follows).
                recomputeFilteredNotes()
                // Re-issue the live primary REQ so the relay stops streaming the
                // unfollowed author's future notes.
                resubscribePrimaryToConnected()
                notificationManager.showFollow(displayName, FollowKind.UNFOLLOWED, undo, pubkey = pubkey)
                Result.success(Unit)
            },
            onFailure = {
                if (it is ContactManager.FollowActionError.ListUnavailable) {
                    // Kept queued and retried; never published against an unknown list.
                    queueFollowAction(pubkey, follow = false)
                    return Result.failure(it)
                }
                notificationManager.showFollow(displayName, FollowKind.FAILED(it.message ?: "Failed"), pubkey = pubkey)
                Result.failure(it)
            },
        )
    }

    internal fun FeedService.restoreContactListImpl(pTags: List<List<String>>, content: String) {
        val contactResult = contactManager.parseContactList(pTags)
        _followedPubkeys.value = contactResult.pubkeys
        contactListContent = content
        // The backup's own tags, plus the current list's non-follow tags it
        // lacks (a relay-history backup holds only its p tags).
        contactListTags = pTags + contactListTags.filter { it.isNotEmpty() && it[0] != "p" && it !in pTags }
        publishContactList(contactResult.pubkeys, ContactManager.FollowEdit(replaceWith = contactResult.pubkeys))
    }

    /**
     * Block for the active account. This wrote the legacy flat `blockedNpubs`,
     * which the feed filter ignores once a per-account list exists, and then
     * published that stale list as the owner's mute list, dropping anyone
     * blocked from Settings and, on a second account, signing as the owner.
     */
    internal fun FeedService.blockUserImpl(hexPubkey: String) {
        val npub = nostrService.hexToNpub(hexPubkey) ?: return
        if (npub in configStore.config.value.blockedForActiveAccount()) return
        configStore.blockProfile(npub)
        publishActiveMuteList(add = listOf(npub))
        _notes.value = _notes.value.filter { it.pubkey != hexPubkey }
        recomputeFilteredNotes()
    }

    internal fun FeedService.unblockUserImpl(hexPubkey: String) {
        val npub = nostrService.hexToNpub(hexPubkey) ?: return
        if (npub !in configStore.config.value.blockedForActiveAccount()) return
        val privateBefore = configStore.config.value.let { it.privateBlockedNpubsPerAccount[it.activeOrOwnerNpub()].orEmpty() }
        configStore.unblockProfile(npub)
        publishActiveMuteList(remove = listOf(npub), privateBefore = privateBefore)
    }
