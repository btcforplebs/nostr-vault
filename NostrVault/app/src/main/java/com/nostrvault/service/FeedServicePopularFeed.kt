package com.nostrvault.service

import android.util.Log
import com.nostrvault.data.model.*
import com.nostrvault.relay.HavenBridge
import kotlinx.coroutines.*
import kotlinx.coroutines.flow.*
import kotlinx.serialization.json.*
import com.nostrvault.service.FeedService.Companion.TAG
import com.nostrvault.service.FeedService.Companion.THREAD_REPLIES_SETTLE_MS

    // ══════════════════════════════════════════════════════════════════

    // Popular feed

    // ══════════════════════════════════════════════════════════════════

    internal fun FeedService.loadPopularFeed() {
        _isLoadingPopular.value = true
        _connectionStatus.value = "Computing popular..."
        resetFeedThreadReplies()

        scope.launch(Dispatchers.Default) {
            try {
                val resultJson = HavenBridge.computePopularNotes()
                if (resultJson.isNullOrEmpty()) {
                    withContext(Dispatchers.Main.immediate) {
                        _isLoadingPopular.value = false
                        _connectionStatus.value = "No popular notes"
                    }
                    return@launch
                }

                val results = json.decodeFromString<List<PopularNoteResult>>(resultJson)
                val notes = results.mapNotNull { r ->
                    FeedNote.fromEvent(r.id, r.pubkey, r.content, r.tags, r.createdAt, r.kind)
                        .takeIf { !it.isNoiseOrSpam() }
                }
                val scores = results.associate { it.id to it.score }

                withContext(Dispatchers.Main.immediate) {
                    _notes.value = notes
                    _popularNoteScores.value = scores
                    _isLoadingPopular.value = false
                    _connectionStatus.value = if (notes.isNotEmpty()) "Popular" else "No popular notes"
                    recomputeFilteredNotes()
                }
            } catch (e: Exception) {
                Log.w(TAG, "Popular feed failed: ${e.message}")
                withContext(Dispatchers.Main.immediate) {
                    _isLoadingPopular.value = false
                    _connectionStatus.value = "Popular feed error"
                }
            }
        }
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
            val trusted = if (_feedMode.value == FeedMode.GLOBAL) globalTrustSet() else null
            val known = _feedThreadReplies.value
            val replies = events.mapNotNull { ev ->
                threadReplyFrom(ev)?.takeIf {
                    it.id !in known && FeedThreadReplies.admits(it, roots, blocked, trusted) &&
                        HavenBridge.verifyEvent(ev.toString())
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
