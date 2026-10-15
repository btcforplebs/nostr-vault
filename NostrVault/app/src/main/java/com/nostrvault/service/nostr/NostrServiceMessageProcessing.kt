package com.nostrvault.service

import com.nostrvault.relay.HavenBridge
import kotlinx.coroutines.*
import kotlinx.coroutines.flow.*
import kotlinx.coroutines.sync.withLock
import kotlinx.serialization.json.*
import kotlin.concurrent.withLock
import com.nostrvault.service.NostrService.Companion.BUFFER_FLUSH_DELAY_MS
import com.nostrvault.service.NostrService.Companion.MAX_EVENTS
import com.nostrvault.service.NostrService.Companion.MAX_SEEN_IDS
import com.nostrvault.service.NostrService.Companion.REPLACEABLE_STATE_KINDS
import com.nostrvault.service.NostrService.Companion.TRIM_SEEN_IDS
import android.util.Log
import com.nostrvault.BuildConfig
import com.nostrvault.service.NostrService.Companion.TAG

    internal fun NostrService.processEvent(eventObj: JsonObject, relayUrl: String) {
        val id = eventObj["id"]?.jsonPrimitive?.contentOrNull ?: return
        val pubkey = eventObj["pubkey"]?.jsonPrimitive?.contentOrNull ?: return
        val kind = eventObj["kind"]?.jsonPrimitive?.intOrNull ?: return
        val content = eventObj["content"]?.jsonPrimitive?.contentOrNull ?: ""
        val createdAt = eventObj["created_at"]?.jsonPrimitive?.longOrNull ?: return
        val sig = eventObj["sig"]?.jsonPrimitive?.contentOrNull ?: ""

        val tags = eventObj["tags"]?.jsonArray?.map { tagArray ->
            tagArray.jsonArray.map { it.jsonPrimitive.contentOrNull ?: "" }
        } ?: emptyList()

        // Reject future-dated events (>60s in future)
        val nowSecs = System.currentTimeMillis() / 1000
        if (createdAt > nowSecs + 60) return

        // Process metadata and relay list events immediately (before dedup).
        // These overwrite cached state (profiles, relay lists, the owner's blocked
        // list), so only a validly signed, newest-seen event may do that.
        if (kind in REPLACEABLE_STATE_KINDS) {
            if (kind == 10000 && pubkey != ownerHexPubkey) return
            if (!acceptReplaceable(eventObj, kind, pubkey, createdAt)) return
        }
        when (kind) {
            0 -> {
                parseAndCacheProfile(pubkey, content, createdAt)
                return
            }
            10002 -> {
                parseRelayListEvent(pubkey, tags, createdAt)
                return
            }
            10050 -> {
                parseDmRelayListEvent(pubkey, tags)
                return
            }
            10063 -> {
                parseServerListEvent(pubkey, tags)
                return
            }
            10000 -> {
                parseMuteListEvent(tags)
                return
            }
        }

        // Dedup check
        if (!markSeen(id)) return

        // Extract media URLs from content
        val mediaItems = extractMediaURLs(content, pubkey, tags, createdAt)

        val event = NostrEvent(
            id = id,
            pubkey = pubkey,
            createdAt = createdAt,
            kind = kind,
            tags = tags,
            content = content,
            sig = sig,
        )

        // Buffer for batched flush
        bufferLock.withLock {
            eventBuffer.add(event to mediaItems)
        }
        scheduleBufferFlush()
    }

    /**
     * True when [eventObj] is validly signed and not older than the newest event of
     * the same kind and author already accepted. Records it as the newest.
     */
    internal fun NostrService.acceptReplaceable(eventObj: JsonObject, kind: Int, pubkey: String, createdAt: Long): Boolean {
        val key = "$kind:$pubkey"
        // A profile saved on disk counts as seen, so after a restart an older
        // signed kind-0 cannot replace a newer one.
        val seen = replaceableNewest[key] ?: if (kind == 0) _profiles.value[pubkey]?.createdAt else null
        if (seen != null && createdAt < seen) return false
        if (!HavenBridge.verifyEvent(eventObj.toString())) return false
        replaceableNewest.merge(key, createdAt) { a, b -> maxOf(a, b) }
        return createdAt >= (replaceableNewest[key] ?: createdAt)
    }

    internal fun NostrService.handleEOSE(subId: String, relayUrl: String) {
        // Close historical (one-shot) subscriptions
        if (subId.contains("-hist-")) {
            closeSubscription(relayUrl, subId)
        }

        activeSubscriptionCount--
        if (activeSubscriptionCount <= 0) {
            activeSubscriptionCount = 0
            scope.launch(Dispatchers.Main.immediate) {
                _isFetching.value = false
            }
            fetchWatchdogJob?.cancel()

            // Sort events by created_at descending
            events = events.sortedByDescending { it.createdAt }
            _eventUpdates.tryEmit(Unit)
        }
    }

    // ══════════════════════════════════════════════════════════════════
    // Event batching
    // ══════════════════════════════════════════════════════════════════

    internal fun NostrService.scheduleBufferFlush() {
        if (bufferFlushJob != null) return
        bufferFlushJob = scope.launch {
            delay(BUFFER_FLUSH_DELAY_MS)
            flushEventBuffer()
        }
    }

    private fun NostrService.flushEventBuffer() {
        val batch = bufferLock.withLock {
            val copy = eventBuffer.toList()
            eventBuffer.clear()
            bufferFlushJob = null
            copy
        }

        if (batch.isEmpty()) return

        val newEvents = batch.map { it.first }
        val newMedia = batch.flatMap { it.second }

        events = (events + newEvents)
            .sortedByDescending { it.createdAt }
            .take(MAX_EVENTS)

        noteMedia = noteMedia + newMedia
        _eventUpdates.tryEmit(Unit)
    }

    // ══════════════════════════════════════════════════════════════════
    // Deduplication
    // ══════════════════════════════════════════════════════════════════

    fun NostrService.markSeen(id: String): Boolean = seenLock.withLock {
        if (seenEventIds.contains(id)) return@withLock false
        seenEventIds.add(id)
        if (seenEventIds.size > MAX_SEEN_IDS) {
            val excess = seenEventIds.size - TRIM_SEEN_IDS
            val iter = seenEventIds.iterator()
            repeat(excess) {
                if (iter.hasNext()) {
                    iter.next()
                    iter.remove()
                }
            }
        }
        true
    }

    internal fun NostrService.clearSeen() = seenLock.withLock {
        seenEventIds.clear()
    }

    /** Stores an EVENT for [subId]; true once the relay is done (EOSE/CLOSED). */
    internal fun NostrService.handleRawQueryMessage(
        msg: String,
        subId: String,
        collected: MutableMap<String, JsonObject>,
    ): Boolean {
        val parsed = try { json.parseToJsonElement(msg).jsonArray } catch (_: Exception) { return false }
        if (parsed.size < 2) return false
        val type = (parsed[0] as? JsonPrimitive)?.contentOrNull ?: return false
        if ((parsed[1] as? JsonPrimitive)?.contentOrNull != subId) return false
        return when (type) {
            "EVENT" -> {
                val ev = parsed.getOrNull(2) as? JsonObject
                val id = (ev?.get("id") as? JsonPrimitive)?.contentOrNull
                if (ev != null && id != null) collected[id] = ev
                false
            }
            "EOSE", "CLOSED" -> true
            else -> false
        }
    }

    /**
     * Process a raw relay message. Called from background dispatcher.
     * Handles EVENT, EOSE, OK, NOTICE, AUTH messages.
     */
    internal fun NostrService.processRelayMessageImpl(message: String, relayUrl: String) {
        try {
            val parsed = json.parseToJsonElement(message).jsonArray
            if (parsed.isEmpty()) return

            val type = parsed[0].jsonPrimitive.contentOrNull ?: return

            when (type) {
                "EVENT" -> {
                    if (parsed.size < 3) return
                    val eventObj = parsed[2].jsonObject
                    processEvent(eventObj, relayUrl)
                }
                "EOSE" -> {
                    if (parsed.size < 2) return
                    val subId = parsed[1].jsonPrimitive.contentOrNull ?: return
                    handleEOSE(subId, relayUrl)
                }
                "OK" -> {
                    // Event acceptance acknowledgment — no action needed for now
                }
                "NOTICE" -> {
                    if (parsed.size >= 2) {
                        val notice = parsed[1].jsonPrimitive.contentOrNull
                        if (BuildConfig.DEBUG) Log.d(TAG, "NOTICE from $relayUrl: $notice")
                    }
                }
                "AUTH" -> {
                    // NIP-42 auth challenge — handled by specific services
                }
            }
        } catch (e: Exception) {
            Log.w(TAG, "Failed to parse relay message: ${e.message}")
        }
    }

    internal fun NostrService.injectEventImpl(event: NostrEvent) {
        if (!markSeen(event.id)) return
        val mediaItems = extractMediaURLs(event.content, event.pubkey, event.tags, event.createdAt)
        bufferLock.withLock {
            eventBuffer.add(event to mediaItems)
        }
        scheduleBufferFlush()
    }
