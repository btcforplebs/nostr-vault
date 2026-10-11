package com.nostrvault.service

import android.util.Log
import com.nostrvault.BuildConfig
import com.nostrvault.data.model.*
import com.nostrvault.data.remote.WebSocketClient
import kotlinx.coroutines.*
import kotlinx.coroutines.flow.*
import kotlinx.serialization.json.*
import java.util.UUID
import java.util.concurrent.ConcurrentHashMap
import com.nostrvault.service.FeedService.Companion.TAG
import com.nostrvault.service.FeedService.Companion.EXTENDED_NETWORK_TIMEOUT_MS
import com.nostrvault.service.FeedService.Companion.EXTENDED_NETWORK_CACHE_MS
import com.nostrvault.service.FeedService.Companion.PARTIAL_EXTENDED_NETWORK_CACHE_MS
import com.nostrvault.service.FeedService.Companion.EXTENDED_NETWORK_CHUNK

    /**
     * Builds the discovery feed's author set: the people your follows follow,
     * ranked by how many of your follows follow them.
     *
     * This used to walk [NostrService.relayLists] — the kind-10002 relay lists
     * the app happened to have cached, for DM partners and anyone scrolled past
     * in Global — and give each of them a count of exactly 1. That is not the
     * second hop of your follow graph, and with every count tied at 1 the
     * ranking was arbitrary. [ContactManager.countMutualFollows], the real
     * tally, was ported to Android and never called. This fetches the kind-3
     * follow list of each person you follow, the way iOS
     * `fetchExtendedNetworkInParallel` does, and counts those.
     *
     * Each follow's list is kept once, newest revision wins, so a follow whose
     * kind-3 sits on three relays does not vote three times.
     */
    internal suspend fun FeedService.loadExtendedNetwork() {
        _isLoadingExtendedNetwork.value = true
        try {
            val follows = _followedPubkeys.value
            if (follows.isEmpty()) {
                withContext(Dispatchers.Main.immediate) { _isLoadingExtendedNetwork.value = false }
                return
            }

            val config = configStore.config.value
            val relayUrls = buildList {
                config.nostrURL?.let { add(it) }
                config.inboxRelays?.let { addAll(it) }
                addAll(config.activeFeedRelays)
                addAll(config.activeBlastrRelays)
            }.distinct()
            if (relayUrls.isEmpty()) {
                withContext(Dispatchers.Main.immediate) { _isLoadingExtendedNetwork.value = false }
                return
            }

            // Newest kind-3 per followed pubkey: created_at to its p-tags.
            val followLists = ConcurrentHashMap<String, Pair<Long, List<List<String>>>>()
            val chunks = follows.chunked(EXTENDED_NETWORK_CHUNK)
            var everyRelayAnswered = true

            coroutineScope {
                relayUrls.map { relayUrl ->
                    async(Dispatchers.IO) {
                        val client = WebSocketClient(
                            url = relayUrl,
                            scope = scope,
                            trustLocalhost = relayUrl.contains("localhost") || relayUrl.contains("127.0.0.1"),
                        )
                        // This relay has answered when it has EOSE'd every chunk
                        // it was asked for — not after the first one, which is
                        // what iOS used to do and why more than one chunk of
                        // follows lost most of its lists.
                        val answered = CompletableDeferred<Unit>()
                        var eoseSeen = 0
                        // One kind-3 per follow, each up to thousands of tags:
                        // parsing these on Main stalled the feed for seconds
                        // while it loaded. `followLists` is concurrent and
                        // `eoseSeen` is only touched by this one collector.
                        val collector = scope.launch(processingDispatcher) {
                            client.messages.collect { msg ->
                                try {
                                    val parsed = json.parseToJsonElement(msg).jsonArray
                                    when (parsed.getOrNull(0)?.jsonPrimitive?.contentOrNull) {
                                        "EVENT" -> {
                                            val eventObj = parsed.getOrNull(2)?.jsonObject ?: return@collect
                                            if (eventObj["kind"]?.jsonPrimitive?.intOrNull != 3) return@collect
                                            val author = eventObj["pubkey"]?.jsonPrimitive?.contentOrNull
                                                ?: return@collect
                                            val createdAt = eventObj["created_at"]?.jsonPrimitive?.longOrNull ?: 0L
                                            val tags = eventObj["tags"]?.jsonArray?.map { tagArr ->
                                                tagArr.jsonArray.map { it.jsonPrimitive.contentOrNull ?: "" }
                                            } ?: emptyList()
                                            followLists.merge(author, createdAt to tags) { old, new ->
                                                if (new.first > old.first) new else old
                                            }
                                        }
                                        "EOSE" -> {
                                            eoseSeen++
                                            if (eoseSeen >= chunks.size) answered.complete(Unit)
                                        }
                                    }
                                } catch (_: Exception) {}
                            }
                        }
                        try {
                            client.connect()
                            for ((index, chunk) in chunks.withIndex()) {
                                val authors = chunk.joinToString(",") { "\"$it\"" }
                                val subId = "ext-$index-${UUID.randomUUID().toString().take(4)}"
                                client.send("[\"REQ\",\"$subId\",{\"kinds\":[3],\"authors\":[$authors]}]")
                            }
                            withTimeoutOrNull(EXTENDED_NETWORK_TIMEOUT_MS) { answered.await() } != null
                        } finally {
                            collector.cancel()
                            client.disconnect()
                        }
                    }
                }.awaitAll().forEach { relayAnswered ->
                    if (!relayAnswered) everyRelayAnswered = false
                }
            }

            val followSet = follows.toSet()
            val mutualCounts = mutableMapOf<String, Int>()
            for ((_, list) in followLists) {
                for ((pk, count) in contactManager.countMutualFollows(list.second, followSet)) {
                    mutualCounts[pk] = (mutualCounts[pk] ?: 0) + count
                }
            }
            val extended = contactManager.rankExtendedNetwork(mutualCounts)
            if (BuildConfig.DEBUG) Log.d(
                TAG,
                "Extended network: ${followLists.size}/${follows.size} follow lists, " +
                    "${mutualCounts.size} candidates, complete=$everyRelayAnswered",
            )

            withContext(Dispatchers.Main.immediate) {
                _extendedNetworkPubkeys.value = extended
                _isLoadingExtendedNetwork.value = false
                // A tally that ended on a relay timeout is missing follow
                // lists. It is still used — better than an empty discovery
                // feed — but it is re-asked for in five minutes instead of
                // being frozen in place for the full hour. Mirrors iOS.
                lastExtendedNetworkLoadTime = System.currentTimeMillis()
                extendedNetworkWasPartial = !everyRelayAnswered
            }
        } catch (e: Exception) {
            Log.w(TAG, "Extended network load failed: ${e.message}")
            withContext(Dispatchers.Main.immediate) {
                _isLoadingExtendedNetwork.value = false
            }
        }
    }

    internal fun FeedService.needsExtendedNetworkRefresh(): Boolean {
        val age = if (extendedNetworkWasPartial) PARTIAL_EXTENDED_NETWORK_CACHE_MS else EXTENDED_NETWORK_CACHE_MS
        return System.currentTimeMillis() - lastExtendedNetworkLoadTime > age
    }
