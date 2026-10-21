package com.nostrvault.service

import com.nostrvault.data.model.*
import com.nostrvault.data.remote.WebSocketClient
import kotlinx.coroutines.*
import kotlinx.coroutines.flow.*
import kotlinx.serialization.json.*
import java.util.UUID
import com.nostrvault.service.FeedService.Companion.NOTE_FETCH_TIMEOUT_MS

    // ══════════════════════════════════════════════════════════════════
    // Pagination
    // ══════════════════════════════════════════════════════════════════

    fun FeedService.loadMore() {
        // In-flight guard: scroll-triggered, so without this it re-fires on every
        // bottom-reach and leaks a client + collector per relay each time.
        // Popular is a fixed ranked set: an older page would add unscored
        // notes under it. Feeds with their own service have no timeline page.
        val mode = _feedMode.value
        if (mode == FeedMode.POPULAR || mode in OWN_SERVICE_MODES) return
        // An author-scoped feed with no authors would page the whole network
        // (the filter just omits `authors`). Same guards as the live REQ.
        if (mode == FeedMode.DISCOVERY && _extendedNetworkPubkeys.value.isEmpty()) return
        if (mode == FeedMode.FOLLOWING && _followedPubkeys.value.isEmpty()) return
        if (!isLoadingMore.compareAndSet(false, true)) return
        // The note list outlives a mode switch: Polls pages from its oldest
        // poll, as the live REQ does, or another feed's notes would skip polls.
        val last = if (mode == FeedMode.POLLS) _notes.value.lastOrNull { it.kind == NIP88Poll.KIND } else _notes.value.lastOrNull()
        val oldest = last?.createdAt ?: run {
            isLoadingMore.set(false)
            return
        }
        _loadingOlder.value = true
        val config = configStore.config.value
        val relayUrls = buildList {
            config.nostrURL?.let { add(it) }
            // Local feed cache first — pagination inside the sync window is
            // served from disk without hitting the network.
            config.localRelayURL("feed")?.let { add(it) }
            config.inboxRelays?.let { addAll(it) }
            // Match the live feed relay set so paginating older notes also
            // reaches follows who publish to feed/blastr relays.
            addAll(config.activeFeedRelays)
            addAll(config.activeBlastrRelays)
        }.distinct().let { FeedService.relaysForMode(mode, it) }

        scope.launch(Dispatchers.IO) {
            val subId = "feed-hist-${UUID.randomUUID().toString().take(8)}"
            val clients = mutableListOf<WebSocketClient>()
            val collectors = mutableListOf<Job>()
            try {
                for (relayUrl in relayUrls) {
                    // The live REQ's own scope (authors, topics), so a page
                    // brings this feed's notes, not every feed's.
                    val pageFilter = pageScope(mode, relayUrl) ?: continue
                    val client = WebSocketClient(url = relayUrl, scope = scope, trustLocalhost = relayUrl.contains("localhost") || relayUrl.contains("127.0.0.1"))
                    clients.add(client)

                    // Track the collector so it can be cancelled on cleanup —
                    // WebSocketClient.messages is a SharedFlow that never completes,
                    // so disconnect() alone leaves this coroutine (and the client)
                    // pinned in memory forever.
                    collectors.add(scope.launch(processingDispatcher) {
                        client.messages.collect { msg ->
                            launch(processingDispatcher) {
                                processAccumulatorMessage(msg, relayUrl)
                            }
                        }
                    })

                    client.connect()

                    val filter = buildString {
                        append("{\"kinds\":[${primaryFeedKinds()}]")
                        append(pageFilter)
                        append(",\"until\":${oldest.time / 1000 - 1}")
                        append(",\"limit\":100}")
                    }

                    client.send("[\"REQ\",\"$subId\",$filter]")
                }

                // The follows' own relays, each asked only for the follows it
                // was picked for, on the socket it already has: its live feed
                // socket, else the pooled lookup socket, which also leaves a
                // relay that refused it alone for a while. No socket per page.
                for ((relayUrl, authors) in outboxPlan) {
                    if (authors.isEmpty() || relayUrl in relayUrls) continue
                    // The plan's follows for this relay (followAuthors).
                    val pageFilter = pageScope(mode, relayUrl) ?: continue
                    val filter = buildString {
                        append("{\"kinds\":[${primaryFeedKinds()}]")
                        append(pageFilter)
                        append(",\"until\":${oldest.time / 1000 - 1}")
                        append(",\"limit\":100}")
                    }
                    val feedClient = feedClients[relayUrl]
                        ?.takeIf { it.connectionState.value == WebSocketClient.ConnectionState.CONNECTED }
                    collectors.add(scope.launch(Dispatchers.IO) {
                        if (feedClient != null) {
                            // Its own collector already hands every message to the accumulator.
                            askOnFeedClient(feedClient, subId, listOf(filter)) {}
                        } else {
                            lookupPool.query(relayUrl, subId, listOf(filter), NOTE_FETCH_TIMEOUT_MS) { msg ->
                                processAccumulatorMessage(msg, relayUrl)
                            }
                        }
                    })
                }

                delay(NOTE_FETCH_TIMEOUT_MS)
            } finally {
                collectors.forEach { it.cancel() }
                clients.forEach { it.disconnect() }
                _loadingOlder.value = false
                isLoadingMore.set(false)
            }
        }
    }

    /**
     * The page's scope, or null when it must not be asked: the feed changed
     * while the page was starting, or an author-scoped feed has no authors,
     * which would page the whole network. Only Global, Recipes (its topics)
     * and the shield's Everyone go out without authors.
     */
    private fun FeedService.pageScope(mode: FeedMode, relayUrl: String): String? {
        if (_feedMode.value != mode) return null
        val sb = StringBuilder()
        if (!appendPrimaryScope(sb, relayUrl)) return null
        val everyone = configStore.config.value.globalShowsEveryone &&
            (if (mode == FeedMode.MEDIA) _mediaFeedMode.value else longFormScope()) == MediaFeedMode.GLOBAL
        val unscopedOk = mode == FeedMode.GLOBAL || mode == FeedMode.RECIPES || everyone
        return sb.toString().takeIf { unscopedOk || "\"authors\"" in it }
    }
