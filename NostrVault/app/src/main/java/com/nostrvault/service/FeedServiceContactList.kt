package com.nostrvault.service

import android.util.Log
import com.nostrvault.BuildConfig
import com.nostrvault.data.model.*
import com.nostrvault.data.remote.WebSocketClient
import com.nostrvault.relay.HavenBridge
import kotlinx.coroutines.*
import kotlinx.coroutines.flow.*
import kotlinx.coroutines.sync.withLock
import kotlinx.serialization.json.*
import java.util.UUID
import java.util.concurrent.locks.ReentrantLock
import kotlin.concurrent.withLock
import com.nostrvault.service.FeedService.Companion.TAG
import com.nostrvault.service.FeedService.PendingFollow
import com.nostrvault.service.FeedService.Companion.CONTACT_LOAD_TIMEOUT_MS
import com.nostrvault.service.FeedService.Companion.CONTACT_NEWEST_GRACE_MS
import java.util.concurrent.ConcurrentHashMap

    internal fun FeedService.queueFollowAction(pubkey: String, follow: Boolean) {
        pendingFollowActions.removeAll { it.pubkey == pubkey }
        pendingFollowActions.add(PendingFollow(pubkey, follow, currentSnapshotKey()))
        // "Following Name…" with a spinner until the list loads, then the
        // outcome in the same pill (iOS addPending). A list that could not be
        // loaded keeps it waiting; the tap is retried, never published blind.
        notificationManager.addPendingFollow(pubkey, profileDisplayName(pubkey), follow)
        if (!_isLoadingContacts.value) scope.launch { loadContactList() }
    }

    /** Applies queued taps only once the real list is known; after a timeout they stay queued. */
    private fun FeedService.applyPendingFollowActions() {
        if (!contactManager.mayPublishFollowList(_hasAttemptedContactLoad.value, _isLoadingContacts.value, contactListConfirmed)) {
            // The load finished without the real list. The taps stay queued
            // (a later load applies them), but the spinner doesn't spin on.
            if (_hasAttemptedContactLoad.value && !_isLoadingContacts.value) {
                pendingFollowActions.forEach {
                    notificationManager.failPendingFollow(it.pubkey, "Couldn't load your follow list. Not changing it.")
                }
            }
            return
        }
        if (pendingFollowActions.isEmpty()) return
        val account = currentSnapshotKey()
        val (actions, dropped) = pendingFollowActions.partition { it.account == account }
        pendingFollowActions.clear()
        dropped.forEach { notificationManager.dismissPendingFollow(it.pubkey) }
        for (action in actions) {
            if (action.follow) followUser(action.pubkey) else unfollowUser(action.pubkey)
            // Applied with no pill of its own (already done, or refused by the
            // safety check), and not queued again: nothing is pending now.
            if (pendingFollowActions.none { it.pubkey == action.pubkey }) {
                notificationManager.dismissPendingFollow(action.pubkey)
            }
        }
    }

    internal suspend fun FeedService.loadContactList() {
        val myGeneration = ++contactLoadGeneration
        _isLoadingContacts.value = true
        if (BuildConfig.DEBUG) Log.d(TAG, "loadContactList: starting, current followedPubkeys=${_followedPubkeys.value.size}")

        // Prime the local-edit guard from THIS account's durable backup so a relay
        // copy older than our last known edit can't clobber it — even on a cold
        // start where the feed snapshot expired. Reset across account switches so a
        // previous account's timestamp can't block the new account's relay copy.
        val accountKey = configStore.config.value.activeAccountNpub
            ?: configStore.config.value.ownerNpub
        if (ownContactListAccountKey != accountKey) {
            ownContactListAccountKey = accountKey
            ownContactListCreatedAt = 0L
        }
        ownContactListCreatedAt = maxOf(
            ownContactListCreatedAt,
            followingBackupService.latestContactListCreatedAt(accountKey),
        )

        withContext(Dispatchers.IO) {
            try {
                val fetched = withTimeoutOrNull(CONTACT_LOAD_TIMEOUT_MS) {
                    fetchContactListFromRelays()
                }
                val result = fetched?.best
                if (myGeneration != contactLoadGeneration) {
                    // Superseded by a newer call (e.g. an account switch) — this
                    // result may belong to a different account entirely, discard it.
                    if (BuildConfig.DEBUG) Log.d(TAG, "loadContactList: discarding stale result (generation $myGeneration superseded)")
                    return@withContext
                }
                if (result != null && result.third >= ownContactListCreatedAt &&
                    result.third != refusedContactListCreatedAt
                ) {
                    val (pubkeys, content, createdAt) = result
                    if (BuildConfig.DEBUG) Log.d(TAG, "loadContactList: committing ${pubkeys.size} followed pubkeys (created_at=$createdAt)")
                    withContext(Dispatchers.Main.immediate) {
                        contactListConfirmed = true
                        _followedPubkeys.value = pubkeys
                        contactListContent = content
                        ownContactListCreatedAt = maxOf(ownContactListCreatedAt, createdAt)
                        _hasAttemptedContactLoad.value = true
                        _isLoadingContacts.value = false
                        recomputeFilteredNotes()
                        // Re-issue the live primary REQ so a freshly-loaded (or
                        // refreshed-from-stale-snapshot) follow set streams new
                        // notes onto already-connected relays without a manual refresh.
                        resubscribePrimaryToConnected()

                        // Auto-snapshot for following backup
                        followingBackupService.maybeCreateSnapshot(
                            pubkeys = pubkeys,
                            pTags = pubkeys.map { listOf("p", it) },
                            contactListContent = content,
                            contactListCreatedAt = createdAt,
                            forAccountKey = accountKey,
                        )
                    }
                } else if (result != null) {
                    // The newest relay kind-3 is OLDER than the list we last
                    // published/committed locally — our latest edit (e.g. a fresh
                    // follow) hasn't propagated to these relays yet, so committing it
                    // would silently drop follows. Keep the local set and re-publish
                    // so the network catches up (self-heal).
                    Log.w(TAG, "loadContactList: relay kind-3 stale (relay created_at=${result.third} < local $ownContactListCreatedAt) — keeping ${_followedPubkeys.value.size} local follows and re-publishing")
                    withContext(Dispatchers.Main.immediate) {
                        contactListConfirmed = true
                        _hasAttemptedContactLoad.value = true
                        _isLoadingContacts.value = false
                        // Not over a relay copy more than twice its size: the
                        // local list may be an old cached one, not a fresh edit.
                        val local = _followedPubkeys.value
                        if (ContactManager.mayRepublish(local.size, relaySize = result.first.size)) {
                            publishContactList(local)
                        } else {
                            Log.w(TAG, "loadContactList: not re-publishing ${local.size} local follows over ${result.first.size} on relays")
                        }
                    }
                } else {
                    Log.w(TAG, "loadContactList: no contact list found (confirmed new account=${fetched?.confirmed == true})")
                    withContext(Dispatchers.Main.immediate) {
                        // Only a genuinely new account (every relay answered,
                        // none had a list, or a key setup just made) may follow
                        // from empty; a timeout may not.
                        contactListConfirmed = fetched?.confirmed == true ||
                            FreshAccountKeys.isFresh(appContext, nostrService.activeHexPubkey)
                        _hasAttemptedContactLoad.value = true
                        _isLoadingContacts.value = false
                    }
                }
            } catch (e: Exception) {
                Log.w(TAG, "Contact list load failed: ${e.message}")
                withContext(Dispatchers.Main.immediate) {
                    _hasAttemptedContactLoad.value = true
                    _isLoadingContacts.value = false
                }
            }
        }
        if (myGeneration == contactLoadGeneration) {
            withContext(Dispatchers.Main.immediate) { applyPendingFollowActions() }
        }
    }

    /** One follow-list fetch: the newest list found, and whether the list is known (see ContactManager.loadConfirmsList). */
    private data class ContactFetch(val best: Triple<List<String>, String, Long>?, val confirmed: Boolean)

    private suspend fun FeedService.fetchContactListFromRelays(): ContactFetch? {
        val config = configStore.config.value
        val relayUrls = buildList {
            config.nostrURL?.let { add(it) }
            config.inboxRelays?.let { addAll(it) }
            config.activeBlastrRelays.let { addAll(it) }
        }.distinct().take(5)

        if (BuildConfig.DEBUG) Log.d(TAG, "fetchContactList: trying ${relayUrls.size} relays: $relayUrls")
        if (BuildConfig.DEBUG) Log.d(TAG, "fetchContactList: activeHexPubkey=${nostrService.activeHexPubkey.take(16)}...")

        if (relayUrls.isEmpty()) {
            Log.w(TAG, "fetchContactList: no relay URLs configured!")
            return null
        }

        return suspendCancellableCoroutine { cont ->
            var resumed = false
            val lock = ReentrantLock()
            // kind-3 is a REPLACEABLE event: the authoritative version is the one
            // with the newest created_at, NOT whichever relay answers first. Taking
            // first-to-arrive let a stale relay copy overwrite a fresh local edit —
            // e.g. unfollow someone, refresh, and they came back because an older
            // kind-3 won the race. Collect across relays and keep the newest.
            var best: Triple<List<String>, String, Long>? = null   // pubkeys, content, createdAt
            var graceJob: Job? = null
            val tally = ContactManager.EOSETally()

            fun resumeWithBest() {
                lock.withLock {
                    if (resumed) return
                    resumed = true
                    graceJob?.cancel()
                    val confirmed = contactManager.loadConfirmsList(best != null, relayUrls.size, tally.answeredCount())
                    cont.resume(ContactFetch(best, confirmed)) { _, _, _ -> }
                }
            }

            for (relayUrl in relayUrls) {
                scope.launch(Dispatchers.IO) {
                    val client = WebSocketClient(url = relayUrl, scope = scope, trustLocalhost = relayUrl.contains("localhost") || relayUrl.contains("127.0.0.1"))
                    val subId = "contacts-${UUID.randomUUID().toString().take(8)}"
                    tally.sent(subId, relayUrl)

                    // Tracked so it can be cancelled after disconnect — messages is a
                    // SharedFlow that never completes, so this would otherwise leak.
                    // Parsed on Default: a kind-3 can be hundreds of KB of JSON.
                    // Shared state below is behind `lock`.
                    val collector = scope.launch(processingDispatcher) {
                        client.messages.collect { msg ->
                            try {
                                val parsed = json.parseToJsonElement(msg).jsonArray
                                val type = parsed.getOrNull(0)?.jsonPrimitive?.contentOrNull
                                val msgSubId = parsed.getOrNull(1)?.jsonPrimitive?.contentOrNull
                                if (type == "EOSE" && msgSubId != null) {
                                    // Each relay counts once, and only for its own request.
                                    tally.eose(relayUrl, msgSubId)
                                    if (tally.answeredCount() >= relayUrls.size) resumeWithBest()
                                }
                                if (parsed.size >= 3 && type == "EVENT" && msgSubId != null && tally.isAnswer(relayUrl, msgSubId)) {
                                    val eventObj = parsed[2].jsonObject
                                    val kind = eventObj["kind"]?.jsonPrimitive?.intOrNull
                                    // A relay can send anything: only the user's own,
                                    // validly signed list counts.
                                    val author = eventObj["pubkey"]?.jsonPrimitive?.contentOrNull
                                    if (kind == 3 && author == nostrService.activeHexPubkey &&
                                        HavenBridge.verifyEvent(eventObj.toString())) {
                                        val createdAt = eventObj["created_at"]?.jsonPrimitive?.longOrNull ?: 0L
                                        val tags = eventObj["tags"]?.jsonArray?.map { tagArr ->
                                            tagArr.jsonArray.map { it.jsonPrimitive.contentOrNull ?: "" }
                                        } ?: emptyList()
                                        val content = eventObj["content"]?.jsonPrimitive?.contentOrNull ?: ""

                                        val ownerHex = nostrService.activeHexPubkey
                                        val whitelistedNpubs = configStore.config.value.whitelistedNpubs ?: emptyList()
                                        val contactResult = contactManager.parseContactList(tags, ownerHex, whitelistedNpubs)
                                        val pubkeys = contactResult.pubkeys
                                        if (BuildConfig.DEBUG) Log.d(TAG, "fetchContactList: kind:3 from $relayUrl tags=${tags.size} parsed=${pubkeys.size} created_at=$createdAt")
                                        if (pubkeys.isNotEmpty()) {
                                            lock.withLock {
                                                if (best == null || createdAt > best!!.third) {
                                                    best = Triple(pubkeys, content, createdAt)
                                                }
                                                // On the first result, start a short grace window so a
                                                // newer kind-3 from another relay can still win, then resume.
                                                if (graceJob == null && !resumed) {
                                                    graceJob = scope.launch {
                                                        delay(CONTACT_NEWEST_GRACE_MS)
                                                        resumeWithBest()
                                                    }
                                                }
                                            }
                                        }
                                    }
                                }
                            } catch (_: Exception) {}
                        }
                    }

                    client.connect()
                    val ownerHex = nostrService.activeHexPubkey
                    val filter = """{"kinds":[3],"authors":["$ownerHex"],"limit":1}"""
                    if (BuildConfig.DEBUG) Log.d(TAG, "fetchContactList: sending REQ to $relayUrl")
                    client.send("[\"REQ\",\"$subId\",$filter]")

                    delay(CONTACT_LOAD_TIMEOUT_MS)
                    collector.cancel()
                    client.disconnect()
                    // This relay is done. Resume with whatever is best so far (null if
                    // nothing was ever found) — the grace window already covers the
                    // common case; this backstops the all-timeout path.
                    resumeWithBest()
                }
            }
        }
    }

/**
 * A kind 3 that [ownerHex] wrote and signed. A relay can answer a REQ with
 * anything, and Following Backup's Restore republishes the list as yours.
 */
internal fun isOwnSignedContactList(event: JsonObject, ownerHex: String, verify: (String) -> Boolean): Boolean =
    (event["kind"] as? JsonPrimitive)?.intOrNull == 3 &&
        (event["pubkey"] as? JsonPrimitive)?.contentOrNull == ownerHex &&
        verify(event.toString())

    /**
     * Scan configured relays for the owner's historical kind-3 (contact list)
     * events, collecting every distinct version found. Used by Following Backup
     * recovery to restore an older following list. Port of iOS queryRelaysForKind3.
     */
    /** [ownerHex] is the account whose lists to find; Following Backup can pick one that isn't active. */
    internal suspend fun FeedService.scanRelaysForKind3Impl(ownerHex: String = nostrService.activeHexPubkey): List<Kind3Event> {
        val config = configStore.config.value
        val relayUrls = buildList {
            config.nostrURL?.let { add(it) }
            config.inboxRelays?.let { addAll(it) }
            config.activeBlastrRelays.let { addAll(it) }
        }.distinct().take(6)
        if (relayUrls.isEmpty() || ownerHex.isEmpty()) return emptyList()

        val whitelistedNpubs = config.whitelistedNpubs ?: emptyList()
        val collected = ConcurrentHashMap<String, Kind3Event>() // keyed by event id

        coroutineScope {
            relayUrls.map { relayUrl ->
                launch(Dispatchers.IO) {
                    val client = WebSocketClient(
                        url = relayUrl,
                        scope = scope,
                        trustLocalhost = relayUrl.contains("localhost") || relayUrl.contains("127.0.0.1"),
                    )
                    val subId = "k3scan-${UUID.randomUUID().toString().take(8)}"
                    // Parsed off Main (kind-3s are large); `collected` is concurrent.
                    val collector = scope.launch(processingDispatcher) {
                        client.messages.collect { msg ->
                            try {
                                val parsed = json.parseToJsonElement(msg).jsonArray
                                if (parsed.size >= 3 && parsed[0].jsonPrimitive.contentOrNull == "EVENT") {
                                    val eventObj = parsed[2].jsonObject
                                    // Restore republishes this list as yours, so like
                                    // fetchContactList only the owner's signed kind 3 counts.
                                    if (!isOwnSignedContactList(eventObj, ownerHex, HavenBridge::verifyEvent)) return@collect
                                    val id = eventObj["id"]?.jsonPrimitive?.contentOrNull ?: return@collect
                                    if (collected.containsKey(id)) return@collect
                                    val createdAt = eventObj["created_at"]?.jsonPrimitive?.longOrNull ?: 0L
                                    val tags = eventObj["tags"]?.jsonArray?.map { tagArr ->
                                        tagArr.jsonArray.map { it.jsonPrimitive.contentOrNull ?: "" }
                                    } ?: emptyList()
                                    val content = eventObj["content"]?.jsonPrimitive?.contentOrNull ?: ""
                                    val pTags = tags.filter { it.firstOrNull() == "p" }
                                    val pubkeys = contactManager.parseContactList(tags, ownerHex, whitelistedNpubs).pubkeys
                                    if (pubkeys.isNotEmpty()) {
                                        collected[id] = Kind3Event(id, createdAt, pubkeys, pTags, content)
                                    }
                                }
                            } catch (_: Exception) {}
                        }
                    }
                    // Cancelled mid-scan (Following Backup switching account),
                    // the socket and its collector still close.
                    try {
                        client.connect()
                        client.send("[\"REQ\",\"$subId\",{\"kinds\":[3],\"authors\":[\"$ownerHex\"]}]")
                        delay(CONTACT_LOAD_TIMEOUT_MS)
                    } finally {
                        collector.cancel()
                        client.disconnect()
                    }
                }
            }.joinAll()
        }
        return collected.values.sortedByDescending { it.createdAt }
    }
