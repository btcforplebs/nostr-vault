package com.nostrvault.ui.screens.dashboard

import android.util.Log
import androidx.compose.foundation.layout.*
import androidx.compose.material3.*
import androidx.compose.runtime.*
import kotlinx.coroutines.launch
import kotlinx.coroutines.delay
import androidx.lifecycle.viewModelScope
import com.nostrvault.data.model.*
import com.nostrvault.data.remote.WebSocketClient
import com.nostrvault.service.NostrEvent
import com.nostrvault.service.NostrService
import com.nostrvault.ui.theme.*
import com.nostrvault.util.RelayGiven
import kotlinx.coroutines.*
import kotlinx.coroutines.flow.map
import kotlinx.coroutines.sync.withLock
import kotlinx.serialization.json.*
import java.util.UUID
import com.nostrvault.ui.screens.dashboard.DashboardViewModel.Companion.TAG

    internal fun DashboardViewModel.fetchMissingLikedNotes() {
        val owner = nostrService.activeHexPubkey
        if (owner.isEmpty()) return

        viewModelScope.launch(Dispatchers.Default) {
            val events = allEventsMutex.withLock { allEvents.toList() }

            val myLikes = events.filter { it.kind == 7 && it.pubkey == owner }
            val likedAuthor = HashMap<String, String>()
            val likedNoteIds = HashSet<String>()
            for (like in myLikes) {
                val target = like.tags.firstOrNull { it.size >= 2 && it[0] == "e" }?.get(1) ?: continue
                likedNoteIds.add(target)
                like.tags.firstOrNull { it.size >= 2 && it[0] == "p" }?.get(1)?.let { likedAuthor[target] = it }
            }

            val existingIds = events.map { it.id }.toSet()
            val missingIds = likedNoteIds.subtract(existingIds).subtract(requestedMissingIds)
            if (missingIds.isEmpty()) return@launch

            for (id in missingIds) requestedMissingIds.add(id)
            Log.d(TAG, "Fetching ${missingIds.size} missing liked notes")

            // You mostly like posts from the feed, which already holds them
            // signed and whole: take those now instead of waiting on relays
            // (iOS #295: primal returned 7 of the last 20 liked posts).
            for (id in missingIds) {
                val event = feedService.getCachedRawEvent(id)?.let(RelayGiven::eventFromJson) ?: continue
                if (event.id == id) nostrService.injectEvent(event)
            }

            val config = configStore.config.value
            val relayUrls = RelayGiven.likedNoteRelays(
                localRoot = config.nostrURL,
                localFeed = config.localRelayURL("feed"),
                feedRelays = config.activeFeedRelays,
                missingIds = missingIds,
                likedAuthor = likedAuthor,
                outboxRelays = nostrService.outboxRelays.value,
            )
            nostrService.fetchNotesByIds(missingIds.toList(), relayUrls)
        }
    }

    /** Merge events from NostrService.events into our allEvents store. */
    internal suspend fun DashboardViewModel.mergeNostrServiceEvents() {
        val serviceEvents = nostrService.events
        allEventsMutex.withLock {
            val existingIds = allEvents.map { it.id }.toHashSet()
            for (event in serviceEvents) {
                // seenIds too: the live subscription marks an event seen before
                // it reaches allEvents, so checking allEvents alone let one
                // arriving on both paths be added twice.
                // Every kind the tab lists, so a liked or zapped comment or
                // highlight fetched for Given is kept.
                if ((event.kind in RELAY_TAB_NOTE_KINDS || event.kind == 7 || event.kind == 9735) &&
                    existingIds.add(event.id) && seenIds.add(event.id)) {
                    allEvents.add(event)
                }
            }
            trimAllEventsLocked()
        }
    }

    // ── Helpers ──────────────────────────────────────────────────

    internal fun DashboardViewModel.buildExternalRelayUrls(): List<String> {
        val urls = mutableListOf<String>()
        configStore.config.value.nostrURL?.let { urls.add(it) }
        urls.addAll(configStore.config.value.readRelays)
        return urls
    }

    internal fun DashboardViewModel.resolveWhitelistedHexPubkeys(): Set<String> {
        return configStore.config.value.whitelistedNpubs
            ?.mapNotNull { nostrService.npubToHex(it) }
            ?.toSet() ?: emptySet()
    }

    /**
     * Query a relay endpoint, collecting events until EOSE or timeout.
     * Uses the shared [seenIds] set to deduplicate across calls.
     */
    internal suspend fun DashboardViewModel.queryRelayEndpoint(
        url: String,
        filters: String,
        subIdPrefix: String,
        timeoutMs: Long,
        /** False for lookups that must not mark ids as seen: a seen id is
         *  dropped by the live subscription, so it would never reach the list. */
        dedupe: Boolean = true,
        /** Set once the relay ends the stored events (EOSE): an empty result is then a real "none". */
        answered: java.util.concurrent.atomic.AtomicBoolean? = null,
    ): Pair<List<NostrEvent>, List<FeedNote>> {
        val rawEvents = mutableListOf<NostrEvent>()
        val contentNotes = mutableListOf<FeedNote>()
        val client = WebSocketClient(url = url, scope = viewModelScope, trustLocalhost = true)
        val subId = "$subIdPrefix-${UUID.randomUUID().toString().take(8)}"
        var eoseReceived = false

        val collectJob = viewModelScope.launch(Dispatchers.IO) {
            client.messages.collect { msg ->
                try {
                    val parsed = json.parseToJsonElement(msg).jsonArray
                    val type = parsed[0].jsonPrimitive.contentOrNull ?: return@collect

                    when (type) {
                        "EVENT" -> {
                            if (parsed.size < 3) return@collect
                            val eventObj = parsed[2].jsonObject
                            val id = eventObj["id"]?.jsonPrimitive?.contentOrNull ?: return@collect
                            if (dedupe && !seenIds.add(id)) return@collect

                            val pubkey = eventObj["pubkey"]?.jsonPrimitive?.contentOrNull ?: return@collect
                            val kind = eventObj["kind"]?.jsonPrimitive?.intOrNull ?: return@collect
                            val content = eventObj["content"]?.jsonPrimitive?.contentOrNull ?: ""
                            val createdAt = eventObj["created_at"]?.jsonPrimitive?.longOrNull ?: return@collect
                            val sig = eventObj["sig"]?.jsonPrimitive?.contentOrNull ?: ""
                            val tags = eventObj["tags"]?.jsonArray?.map { tagArr ->
                                tagArr.jsonArray.map { it.jsonPrimitive.contentOrNull ?: "" }
                            } ?: emptyList()

                            if (kind in listOf(0, 10002, 10050, 10063, 10000)) {
                                nostrService.processRelayMessage(msg, url)
                                return@collect
                            }

                            val nostrEvent = NostrEvent(
                                id = id, pubkey = pubkey, createdAt = createdAt,
                                kind = kind, tags = tags, content = content, sig = sig,
                            )
                            rawEvents.add(nostrEvent)

                            if (kind in RELAY_TAB_NOTE_KINDS) {
                                val note = FeedNote.fromEvent(id, pubkey, content, tags, createdAt, kind)
                                if (!note.isNoiseOrSpam()) {
                                    contentNotes.add(note)
                                }
                            }

                            nostrService.fetchMissingProfiles(listOf(pubkey))
                        }
                        "EOSE" -> {
                            eoseReceived = true
                            answered?.set(true)
                        }
                    }
                } catch (e: Exception) {
                    Log.w(TAG, "Parse error in $subIdPrefix: ${e.message}")
                }
            }
        }

        client.connect()

        var waited = 0L
        while (client.connectionState.value != WebSocketClient.ConnectionState.CONNECTED && waited < 5000) {
            delay(100)
            waited += 100
        }

        if (client.connectionState.value == WebSocketClient.ConnectionState.CONNECTED) {
            val sent = client.send("[\"REQ\",\"$subId\",$filters]")
            if (sent) {
                val deadline = System.currentTimeMillis() + timeoutMs
                while (!eoseReceived && System.currentTimeMillis() < deadline) {
                    delay(200)
                }
            }
        }

        collectJob.cancel()
        client.disconnect()

        return Pair(rawEvents, contentNotes)
    }
