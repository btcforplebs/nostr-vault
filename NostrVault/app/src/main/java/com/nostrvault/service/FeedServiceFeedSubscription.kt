package com.nostrvault.service

import android.util.Log
import com.nostrvault.BuildConfig
import com.nostrvault.data.model.*
import com.nostrvault.data.remote.WebSocketClient
import kotlinx.coroutines.*
import kotlinx.coroutines.flow.*
import kotlinx.serialization.json.*
import com.nostrvault.service.FeedService.Companion.TAG
import com.nostrvault.service.FeedService.Companion.FEED_LOAD_TIMEOUT_MS
import com.nostrvault.service.FeedService.Companion.FEED_RELAY_DOWN_AFTER
import com.nostrvault.service.FeedService.Companion.STAGGER_RELAY_MS

    /**
     * End the timeline REQ on every open feed connection without closing the
     * connection: the mention subscription riding on it doubles as
     * notifications and has to keep running.
     */
    internal fun FeedService.closePrimaryFeedSubscription(subId: String) {
        for (client in feedClients.values) {
            if (client.connectionState.value == WebSocketClient.ConnectionState.CONNECTED) {
                client.send("[\"CLOSE\",\"$subId\"]")
            }
        }
    }

    // ══════════════════════════════════════════════════════════════════

    // Relay subscription

    // ══════════════════════════════════════════════════════════════════

    internal fun FeedService.subscribeToAllRelays() {
        // An author-scoped mode with an empty author set must not subscribe:
        // the filter builder simply omits the `authors` key, so the REQ goes
        // out unrestricted and Discovery quietly becomes Global with no tell.
        // iOS guards this; Android did not.
        if (_feedMode.value == FeedMode.DISCOVERY && _extendedNetworkPubkeys.value.isEmpty()) {
            _isLoadingFeed.value = false
            val followsNobody = _followedPubkeys.value.isEmpty()
            _connectionStatus.value = if (followsNobody) {
                "Follow more people to build your discovery network"
            } else {
                "No follow lists came back from your relays"
            }
            // Nothing to follow yet is a normal state; relays that answered
            // with nothing is a fault worth a red dot.
            _connectionColor.value = if (followsNobody) "yellow" else "red"
            return
        }
        if (_feedMode.value == FeedMode.FOLLOWING && _followedPubkeys.value.isEmpty()) {
            _isLoadingFeed.value = false
            _connectionStatus.value = "Follow someone on Nostr to see their posts here"
            _connectionColor.value = "yellow"
            return
        }

        val relayUrls = feedRelayUrlsWithOutbox()

        // Disconnect stale clients that are no longer in the relay set,
        // and skip URLs that already have a live connection.
        val staleKeys = feedClients.keys - relayUrls.toSet()
        for (key in staleKeys) {
            teardownFeedClient(key)
        }

        _isLoadingFeed.value = true
        isInitialLoad = true
        _connectionStatus.value = "Connecting..."
        _connectionColor.value = "yellow"

        for ((index, relayUrl) in relayUrls.withIndex()) {
            // Reuse an existing connected client instead of creating a duplicate
            val existing = feedClients[relayUrl]
            if (existing != null && existing.connectionState.value == WebSocketClient.ConnectionState.CONNECTED) {
                // Already connected — just re-send the subscription filter
                val label = when (_feedMode.value) {
                    FeedMode.FOLLOWING -> "following"
                    FeedMode.DISCOVERY -> "discovery"
                    FeedMode.GLOBAL -> "global"
                    FeedMode.MEDIA -> "media"
                    FeedMode.POPULAR -> "popular"
                    FeedMode.ARTICLES -> "articles"
                    FeedMode.POLLS -> "polls"
                    FeedMode.RECIPES -> "recipes"
                    FeedMode.LIVE -> "live"
                    FeedMode.MARKETPLACE -> "marketplace"
                    FeedMode.REELS -> "reels"
                    FeedMode.MUSIC -> "music"
                    FeedMode.HASHTAGS -> "hashtags"
                }
                sendPrimaryFeedSubscription(relayUrl, "feed-$label")
                continue
            }
            // Tear down any half-dead client (and its collectors) before replacing it
            if (existing != null) teardownFeedClient(relayUrl)

            scope.launch(Dispatchers.IO) {
                // Stagger external relays
                if (index > 1) delay(index * STAGGER_RELAY_MS)
                connectFeedRelay(relayUrl)
            }
        }

        // Arm feed timeout
        scope.launch {
            delay(FEED_LOAD_TIMEOUT_MS)
            if (_isLoadingFeed.value) {
                _isLoadingFeed.value = false
                _isSyncing.value = false
                flushAccumulator()
            }
        }
    }

    /** Modes whose primary REQ is the follow set (iOS isFollowSetMode, plus Media's Following). */
    internal fun FeedService.isFollowSetMode(): Boolean = when (_feedMode.value) {
        FeedMode.FOLLOWING -> true
        FeedMode.ARTICLES -> _articlesFeedMode.value == MediaFeedMode.FOLLOWING
        FeedMode.POLLS -> _pollsFeedMode.value == MediaFeedMode.FOLLOWING
        FeedMode.MEDIA -> _mediaFeedMode.value == MediaFeedMode.FOLLOWING
        else -> false
    }

    /** Cancel a feed client's collectors and disconnect it. */
    internal fun FeedService.teardownFeedClient(relayUrl: String) {
        feedClientJobs.remove(relayUrl)?.forEach { it.cancel() }
        feedClients.remove(relayUrl)?.disconnect()
        _relayStates.update { it - FeedRelayHealth.key(relayUrl) }
        auxSubsSent.remove(relayUrl)
        feedConnectFailures.remove(relayUrl)
    }

    /** Cancel and disconnect every feed client. */
    internal fun FeedService.teardownAllFeedClients() {
        feedClientJobs.values.forEach { jobs -> jobs.forEach { it.cancel() } }
        feedClientJobs.clear()
        feedClients.values.forEach { it.disconnect() }
        feedClients.clear()
        _relayStates.value = emptyMap()
        auxSubsSent.clear()
    }

    /** Subscription id of the primary feed REQ for the current mode. */
    internal fun FeedService.primaryFeedSubId(): String {
        val label = when (_feedMode.value) {
            FeedMode.FOLLOWING -> "following"
            FeedMode.DISCOVERY -> "discovery"
            FeedMode.GLOBAL -> "global"
            FeedMode.MEDIA -> "media"
            FeedMode.POPULAR -> "popular"
            FeedMode.ARTICLES -> "articles"
            FeedMode.POLLS -> "polls"
            FeedMode.RECIPES -> "recipes"
            FeedMode.LIVE -> "live"
            FeedMode.MARKETPLACE -> "marketplace"
            FeedMode.REELS -> "reels"
            FeedMode.MUSIC -> "music"
            FeedMode.HASHTAGS -> "hashtags"
        }
        return "feed-$label"
    }

    internal fun FeedService.connectFeedRelay(relayUrl: String) {
        val subId = primaryFeedSubId()

        val client = WebSocketClient(
            url = relayUrl,
            scope = scope,
            trustLocalhost = relayUrl.contains("localhost") || relayUrl.contains("127.0.0.1"),
        )
        // Replacing an existing client for this URL: tear down its collectors first.
        teardownFeedClient(relayUrl)
        feedClients[relayUrl] = client

        // Collected on Default, not Main: each message used to cost a Main
        // dispatch just to be handed on to Default.
        val messagesJob = scope.launch(processingDispatcher) {
            client.messages.collect { msg ->
                launch(processingDispatcher) {
                    processAccumulatorMessage(msg, relayUrl)
                }
            }
        }

        val stateJob = scope.launch {
            // A DISCONNECTED straight after a dial is a failed connect; one
            // after CONNECTED is a drop, which the client redials on its own.
            var dialing = false
            client.connectionState.collect { state ->
                if (feedClients[relayUrl] === client) {
                    _relayStates.update { it + (FeedRelayHealth.key(relayUrl) to state) }
                }
                when (state) {
                    WebSocketClient.ConnectionState.CONNECTED -> {
                        dialing = false
                        feedConnectFailures.remove(relayUrl)
                        downRelayUrls.remove(relayUrl)
                        sendPrimaryFeedSubscription(relayUrl, subId)
                        // Mentions go out with the primary feed — they double as
                        // notifications, so they must not wait for feed EOSE.
                        // Not on a follow's own relay: it is asked only for them.
                        if (relayUrl !in outboxPlan) sendMentionSubscription(relayUrl)
                        updateFeedConnectionStatus()
                    }
                    WebSocketClient.ConnectionState.DISCONNECTED -> {
                        // New connection gets a fresh auxiliary-subscription pass
                        auxSubsSent.remove(relayUrl)
                        updateFeedConnectionStatus()
                        if (dialing) {
                            dialing = false
                            val failures = (feedConnectFailures[relayUrl] ?: 0) + 1
                            feedConnectFailures[relayUrl] = failures
                            // The follows this relay was reaching get asked
                            // somewhere else.
                            if (failures >= FEED_RELAY_DOWN_AFTER && downRelayUrls.add(relayUrl)) {
                                reconcileOutboxRelays()
                            }
                        }
                    }
                    WebSocketClient.ConnectionState.CONNECTING,
                    WebSocketClient.ConnectionState.RECONNECTING -> dialing = true
                }
            }
        }
        feedClientJobs[relayUrl] = mutableListOf(messagesJob, stateJob)

        client.connect()
    }

    /**
     * Re-issue the primary REQ to every connected feed client so a changed follow
     * set takes effect on the LIVE stream without a full refresh. Reuses the same
     * subId so the relay replaces the prior subscription (no duplicate stream).
     * Called when contacts finish loading (incl. after a stale-snapshot top-up) and
     * on follow/unfollow — mirrors the iOS resubscribePrimaryIfNeeded reconcile.
     */
    internal fun FeedService.resubscribePrimaryToConnected() {
        if (_feedMode.value == FeedMode.POPULAR) return
        val label = when (_feedMode.value) {
            FeedMode.FOLLOWING -> "following"
            FeedMode.DISCOVERY -> "discovery"
            FeedMode.GLOBAL -> "global"
            FeedMode.MEDIA -> "media"
            FeedMode.POPULAR -> return
            FeedMode.ARTICLES -> "articles"
            FeedMode.POLLS -> "polls"
            FeedMode.RECIPES -> "recipes"
            FeedMode.LIVE -> "live"
            FeedMode.MARKETPLACE -> "marketplace"
            FeedMode.REELS -> return
            FeedMode.MUSIC -> return
            FeedMode.HASHTAGS -> return
        }
        // A changed follow set changes which follows' own relays are needed.
        reconcileOutboxRelays(resend = false)
        for ((relayUrl, client) in feedClients) {
            if (client.connectionState.value == WebSocketClient.ConnectionState.CONNECTED) {
                sendPrimaryFeedSubscription(relayUrl, "feed-$label")
            }
        }
    }

    /**
     * Kinds the primary feed REQ asks for, as a JSON array body. NIP-22
     * comments (1111) ride along so replies from Ditto, Coracle, Snort and
     * Amethyst reach the timeline; accumulateEvent keeps only those on kind 1
     * notes. Articles mode gains nothing from them, so it does not ask. NIP-88
     * polls (1068) draw as a card in the row; their votes are fetched per poll.
     * Generic reposts (16), pictures (20) and highlights (9802) are drawn too
     * ([FeedNote.TIMELINE_KINDS]), the set the relay's feed cache holds.
     */
    internal fun FeedService.primaryFeedKinds(): String = when (_feedMode.value) {
        FeedMode.ARTICLES -> "1,6,30023"
        FeedMode.POLLS -> "${NIP88Poll.KIND}"
        else -> FeedNote.TIMELINE_KINDS.joinToString(",")
    }

    /**
     * The part of a timeline filter that makes it this feed: authors, topics.
     * Shared by the live REQ and older pages, so a page asks for the same
     * feed the screen shows. False when the feed has no timeline REQ.
     */
    internal fun FeedService.appendPrimaryScope(sb: StringBuilder, relayUrl: String): Boolean {
        when (_feedMode.value) {
            FeedMode.FOLLOWING -> {
                // Send the full follow list (iOS does not cap); capping at
                // 500 silently hid notes from any follows beyond that.
                val authors = followAuthors(relayUrl)
                if (authors.isNotEmpty()) {
                    sb.append(",\"authors\":[${authors.joinToString(",") { "\"$it\"" }}]")
                }
            }
            FeedMode.DISCOVERY -> {
                val authors = _extendedNetworkPubkeys.value.take(500)
                if (authors.isNotEmpty()) {
                    sb.append(",\"authors\":[${authors.joinToString(",") { "\"$it\"" }}]")
                }
            }
            FeedMode.GLOBAL -> {
                // No author restriction
            }
            FeedMode.ARTICLES, FeedMode.POLLS -> appendLongFormAuthors(sb, relayUrl)
            // Their own services (Marketplace, Live, Hashtags' #t REQ,
            // Reels) or Wavlake (Music): no timeline REQ.
            FeedMode.MARKETPLACE, FeedMode.LIVE, FeedMode.MUSIC,
            FeedMode.HASHTAGS, FeedMode.REELS -> return false
            FeedMode.RECIPES -> {
                // Ask the relays for the topic rather than pulling every
                // long-form event and throwing most of it away. Only the
                // base topics go on the wire — a "#t" filter matches exact
                // values, so zapcooking-<category> tags cannot be asked for
                // here; RecipeTopics.matches still accepts them locally for
                // recipes that arrive through another subscription.
                sb.append(",\"#t\":[${RecipeTopics.BASE.joinToString(",") { "\"$it\"" }}]")
                appendLongFormAuthors(sb, relayUrl)
            }
            FeedMode.MEDIA -> {
                val authors = when (_mediaFeedMode.value) {
                    MediaFeedMode.FOLLOWING -> followAuthors(relayUrl).take(500)
                    // "Everyone" lifts the Web of Trust scope, like Global notes.
                    MediaFeedMode.GLOBAL ->
                        if (configStore.config.value.globalShowsEveryone) emptyList()
                        else _wotPubkeys.value.take(500).toList()
                }
                if (authors.isNotEmpty()) {
                    sb.append(",\"authors\":[${authors.joinToString(",") { "\"$it\"" }}]")
                }
            }
            FeedMode.POPULAR -> return false // Handled separately
        }
        return true
    }

    internal fun FeedService.sendPrimaryFeedSubscription(relayUrl: String, subId: String) {
        // Reels, Live, Marketplace, Music and Hashtags run their own queries.
        // The feed connections stay up for mentions, but the note timeline
        // idles underneath rather than streaming a list nobody sees.
        if (_feedMode.value in OWN_SERVICE_MODES) {
            // No REQ means no EOSE, which is what sends the follows'
            // reactions and zaps subscriptions: send them now instead.
            if (feedClients[relayUrl] != null && relayUrl !in outboxPlan && auxSubsSent.add(relayUrl)) {
                sendAuxiliarySubscriptions(relayUrl)
            }
            return
        }
        val client = feedClients[relayUrl] ?: return
        val ownerHex = nostrService.activeHexPubkey

        val filter = buildString {
            append("{\"kinds\":[${primaryFeedKinds()}]")
            if (!appendPrimaryScope(this, relayUrl)) return

            // Since timestamp. The note list outlives a mode switch, so Polls
            // counts only polls: another mode's notes would cut older polls off.
            val oldest = if (_feedMode.value == FeedMode.POLLS) {
                _notes.value.lastOrNull { it.kind == NIP88Poll.KIND }?.createdAt
            } else {
                _notes.value.lastOrNull()?.createdAt
            }
            if (oldest != null) {
                append(",\"since\":${oldest.time / 1000}")
            } else if (_feedMode.value == FeedMode.POLLS) {
                // Polls are rare next to notes: a week of them from the people
                // you follow is often none, so ask for the newest however old.
            } else {
                val sevenDaysAgo = System.currentTimeMillis() / 1000 - (7 * 24 * 60 * 60)
                append(",\"since\":$sevenDaysAgo")
            }
            append(",\"limit\":500}")
        }

        // Global under the Web of Trust asks twice, once naming trusted authors
        // and once open. Asked open only, a new account's small web matched
        // almost nothing in a page of strangers and Global rendered blank
        // (iOS #824). Not the local relay: it holds your own vault.
        val filters = if (_feedMode.value == FeedMode.GLOBAL &&
            relayUrl != configStore.config.value.localRelayURL("feed")
        ) {
            val trust = globalTrustSet()
            globalTrustScopedFilters(primaryFeedKinds(), filter, trust, trustedSince(trust))
        } else {
            listOf(filter)
        }

        if (BuildConfig.DEBUG) Log.d(TAG, "sendPrimaryFeedSubscription: $relayUrl subId=$subId followedPubkeys=${_followedPubkeys.value.size}")
        client.send("[\"REQ\",\"$subId\",${filters.joinToString(",")}]")

        // Your own deletion requests (kind 5), so a post deleted on another
        // device leaves this one too. Its own subId: the primary's EOSE is
        // matched exactly, so this one never triggers the auxiliary REQs.
        if (ownerHex.isNotEmpty()) {
            client.send("[\"REQ\",\"del-$subId\",${deleteRequestsFilter(ownerHex)}]")
        }
    }

    private fun FeedService.updateFeedConnectionStatus() {
        val connected = feedClients.values.count {
            it.connectionState.value == WebSocketClient.ConnectionState.CONNECTED
        }
        val total = feedClients.size
        when {
            total == 0 -> {
                _connectionStatus.value = "Disconnected"
                _connectionColor.value = "gray"
            }
            connected == 0 -> {
                _connectionStatus.value = "Connecting..."
                _connectionColor.value = "yellow"
            }
            else -> {
                // Green once the feed is live, i.e. at least one relay (almost always the
                // embedded local relay) is connected. Requiring every public feed/blastr
                // relay to be CONNECTED simultaneously kept the dot stuck off, since at any
                // moment one of them is usually mid-reconnect. The connected/total count is
                // still surfaced in the status text. Matches iOS, where "Live" == green.
                _connectionStatus.value = if (connected < total) "Live ($connected/$total)" else "Live"
                _connectionColor.value = "green"
            }
        }
    }

    internal fun FeedService.handleFeedEOSE(subId: String, relayUrl: String) {
        // Auxiliary subscriptions fire once per connection, on the PRIMARY feed's
        // EOSE only. A prefix match here would also fire on the auxiliary subs'
        // own EOSEs and loop forever (REQ → EOSE → REQ ...) against every relay.
        // Not on a follow's own relay either: it is asked only for them.
        if (subId == primaryFeedSubId() && relayUrl !in outboxPlan && auxSubsSent.add(relayUrl)) {
            sendAuxiliarySubscriptions(relayUrl)
        }

        // Once the feed has loaded, every later EOSE (mentions, reactions,
        // zaps, older pages) lands here too. Forcing a flush on each rebuilt
        // the feed in a burst after every reconcile; the flush timer covers
        // them. Same as iOS.
        if (!flushesOnEose(subId, primaryFeedSubId(), _isLoadingFeed.value, _isSyncing.value)) return
        scope.launch {
            delay(100)
            flushAccumulator()
            _isLoadingFeed.value = false
            _isSyncing.value = false
            isInitialLoad = false
        }
    }

    private fun FeedService.sendMentionSubscription(relayUrl: String) {
        val client = feedClients[relayUrl] ?: return
        val ownerHex = nostrService.activeHexPubkey
        if (ownerHex.isEmpty()) return
        val mentionFilter = """{"kinds":[${FeedNote.TIMELINE_KINDS.joinToString(",")}],"#p":["$ownerHex"],"limit":50}"""
        client.send("[\"REQ\",\"feed-mentions\",$mentionFilter]")
    }

    private fun FeedService.sendAuxiliarySubscriptions(relayUrl: String) {
        val client = feedClients[relayUrl] ?: return
        val ownerHex = nostrService.activeHexPubkey

        // Reactions from followed
        val follows = _followedPubkeys.value.take(200)
        if (follows.isNotEmpty()) {
            val authorsJson = follows.joinToString(",") { "\"$it\"" }
            val reactionFilter = """{"kinds":[7],"authors":[$authorsJson],"limit":150}"""
            client.send("[\"REQ\",\"feed-reactions\",$reactionFilter]")
        }

        // Incoming zaps
        val zapInFilter = """{"kinds":[9735],"#p":["$ownerHex"],"limit":50}"""
        client.send("[\"REQ\",\"feed-zaps-in\",$zapInFilter]")

        // Outgoing zaps
        val zapOutFilter = """{"kinds":[9734],"authors":["$ownerHex"],"limit":50}"""
        client.send("[\"REQ\",\"feed-zaps-out\",$zapOutFilter]")
    }

/** Feeds whose content comes from their own service, never the timeline REQ. */
internal val OWN_SERVICE_MODES = setOf(
    FeedMode.REELS, FeedMode.LIVE, FeedMode.MARKETPLACE, FeedMode.MUSIC, FeedMode.HASHTAGS,
)

/**
 * Whether an EOSE finishes the feed's load: the primary sub's, or any while a
 * load or sync is still in progress. Later EOSEs from auxiliary subs and older
 * pages leave the flush to the timer.
 */
internal fun flushesOnEose(subId: String, primarySubId: String, loading: Boolean, syncing: Boolean): Boolean =
    subId == primarySubId || loading || syncing

/**
 * Where the trusted half of a Global REQ starts: the oldest note on screen
 * from someone in [trust], or a week back when there is none. The open half
 * resumes from the oldest note of all, usually a stranger's from minutes ago,
 * which never asked for your people's older notes.
 */
internal fun FeedService.trustedSince(trust: Set<String>?): Long {
    val oldest = trust?.let { t -> _notes.value.lastOrNull { it.pubkey in t }?.createdAt }
    return oldest?.time?.div(1000) ?: (System.currentTimeMillis() / 1000 - 7 * 24 * 60 * 60)
}

/**
 * Global's primary REQ filters (iOS `trustScopedFilters`). Under the Web of
 * Trust the trusted authors are named in their own filter, so a page of
 * strangers cannot crowd them out, then [openFilter] asks for the rest; the
 * client still drops untrusted authors from both. [trust] null (Everyone) or
 * empty (no graph and no follows) leaves the open filter alone.
 */
internal fun globalTrustScopedFilters(
    kinds: String,
    openFilter: String,
    trust: Set<String>?,
    trustedSince: Long,
): List<String> {
    if (trust.isNullOrEmpty()) return listOf(openFilter)
    val authors = trust.sorted().take(MarketplaceFeedService.AUTHORS_CAP).joinToString(",") { "\"$it\"" }
    val trusted = "{\"kinds\":[$kinds],\"authors\":[$authors],\"since\":$trustedSince,\"limit\":500}"
    return listOf(trusted, openFilter)
}
