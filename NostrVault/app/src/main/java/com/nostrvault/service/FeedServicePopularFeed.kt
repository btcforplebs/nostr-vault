package com.nostrvault.service

import com.nostrvault.relay.VerifiedEvents
import com.nostrvault.data.model.*
import kotlinx.coroutines.*
import kotlinx.coroutines.flow.*
import kotlinx.serialization.json.*
import com.nostrvault.service.FeedService.Companion.THREAD_REPLIES_SETTLE_MS

    // ══════════════════════════════════════════════════════════════════

    // Popular feed

    // ══════════════════════════════════════════════════════════════════

    /** Popular, on the shared local DVM path (FeedServiceLocalDvmFeeds.kt). */
    internal fun FeedService.loadPopularFeed() = loadLocalDvmFeed(FeedMode.POPULAR)

    fun FeedService.setPopularFilter(filter: PopularFilter) {
        _popularFilter.value = filter
        recomputeFilteredNotes()
    }

    // ══════════════════════════════════════════════════════════════════

    // Threaded View replies (Popular, Global)

    // ══════════════════════════════════════════════════════════════════

    internal fun FeedService.resetFeedThreadReplies() {
        synchronized(threadRepliesLock) {
            threadRepliesGeneration++
            threadRepliesRequested.clear()
            threadRepliesPending.clear()
            threadRepliesJob?.cancel()
            threadRepliesJob = null
        }
        if (_feedThreadReplies.value.isNotEmpty()) _feedThreadReplies.value = emptyMap()
    }

    internal suspend fun FeedService.drainThreadReplies(generation: Int) {
        delay(THREAD_REPLIES_SETTLE_MS)
        while (true) {
            val chunk = synchronized(threadRepliesLock) {
                if (generation != threadRepliesGeneration) return
                val next = threadRepliesPending.take(FeedThreadReplies.CHUNK)
                if (next.isEmpty()) {
                    threadRepliesJob = null
                    return
                }
                threadRepliesPending.removeAll(next.toSet())
                next
            }
            val config = configStore.config.value
            val relays = (listOfNotNull(config.nostrURL) +
                config.readRelays).distinct()
            val events = nostrService.queryRawEvents(
                filters = listOf(FeedThreadReplies.filter(chunk)),
                relayUrls = relays,
                timeoutMs = FeedThreadReplies.TIMEOUT_MS,
            )
            if (generation != threadRepliesGeneration) return
            val roots = chunk.toSet()
            val blocked = blockedHexForActiveAccount()
            // Global and Popular: replies pass the web like their posts (TrustGate, Logen 2026-11-04).
            val trusted = if (_feedMode.value == FeedMode.GLOBAL || _feedMode.value.isLocalDvm) globalTrustSet() else null
            val known = _feedThreadReplies.value
            val replies = events.mapNotNull { ev ->
                threadReplyFrom(ev)?.takeIf {
                    it.id !in known && !isDeleted(it.id) && FeedThreadReplies.admits(it, roots, blocked, trusted) &&
                        VerifiedEvents.verify(ev)
                }
            }
            if (replies.isEmpty()) continue
            withContext(Dispatchers.Main.immediate) {
                if (generation == threadRepliesGeneration) {
                    _feedThreadReplies.update { it + replies.associateBy { reply -> reply.id } }
                }
            }
            nostrService.fetchMissingProfiles(replies.map { it.pubkey }.distinct())
        }
    }

    /** A kind 1 note from a raw relay event; the signature is checked by the caller. */
    private fun FeedService.threadReplyFrom(ev: JsonObject): FeedNote? {
        fun str(key: String) = (ev[key] as? JsonPrimitive)?.contentOrNull
        val id = str("id") ?: return null
        val pubkey = str("pubkey") ?: return null
        if (str("kind")?.toIntOrNull() != 1) return null
        val createdAt = (ev["created_at"] as? JsonPrimitive)?.longOrNull ?: return null
        val tags = (ev["tags"] as? JsonArray)?.map { tag ->
            (tag as? JsonArray)?.mapNotNull { (it as? JsonPrimitive)?.contentOrNull }.orEmpty()
        } ?: return null
        return FeedNote.fromEvent(id, pubkey, str("content").orEmpty(), tags, createdAt, 1)
    }

    /**
     * Fetches replies to these Popular or Global posts (once per post per
     * list) from the local relay and the feed relays. Only signature-checked
     * events are kept, and only those [FeedThreadReplies.admits]: real
     * replies into one of these threads, from nobody blocked, and on Global
     * from inside the trust rule. iOS: `FeedService.loadFeedThreadReplies`.
     *
     * Global's list grows with every stream batch, so the ids are queued and
     * one worker asks for them, after a short settle, in chunks — rather than
     * a REQ per batch of three new posts.
     */
    fun FeedService.loadFeedThreadReplies(postIds: List<String>) {
        if (!FeedThreadReplies.fetchesReplies(_feedMode.value)) return
        synchronized(threadRepliesLock) {
            for (id in postIds) if (threadRepliesRequested.add(id)) threadRepliesPending.add(id)
            if (threadRepliesPending.isEmpty() || threadRepliesJob != null) return
            val generation = threadRepliesGeneration
            threadRepliesJob = scope.launch(processingDispatcher) { drainThreadReplies(generation) }
        }
    }
