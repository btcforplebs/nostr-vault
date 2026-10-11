package com.nostrvault.service

import android.util.Log
import com.nostrvault.data.local.EngagementTracker
import com.nostrvault.data.model.*
import kotlinx.coroutines.*
import kotlinx.coroutines.flow.*
import kotlinx.coroutines.sync.withLock
import kotlinx.serialization.json.*
import kotlin.concurrent.withLock
import com.nostrvault.service.FeedService.Companion.TAG
import com.nostrvault.service.FeedService.Companion.MAX_FEED_NOTES
import com.nostrvault.service.FeedService.Companion.MAX_PENDING_NOTES
import com.nostrvault.service.FeedService.Companion.MAX_RAW_EVENT_CACHE
import com.nostrvault.service.FeedService.Companion.FLUSH_INTERVAL_STANDARD_MS
import com.nostrvault.service.FeedService.Companion.FLUSH_INTERVAL_GLOBAL_MS
import com.nostrvault.service.FeedService.Companion.SCROLL_FLUSH_HOLD_MS
import com.nostrvault.service.FeedService.Companion.MAX_SEEN_IDS

    // ══════════════════════════════════════════════════════════════════

    // Background accumulator

    // ══════════════════════════════════════════════════════════════════

    internal fun FeedService.processAccumulatorMessage(message: String, relayUrl: String) {
        try {
            val parsed = json.parseToJsonElement(message).jsonArray
            if (parsed.isEmpty()) return
            val type = parsed[0].jsonPrimitive.contentOrNull ?: return

            when (type) {
                "EVENT" -> {
                    if (parsed.size < 3) return
                    val subId = parsed[1].jsonPrimitive.contentOrNull ?: return
                    val eventObj = parsed[2].jsonObject

                    // Metadata events go to NostrService directly
                    val kind = eventObj["kind"]?.jsonPrimitive?.intOrNull ?: return
                    if (kind in listOf(0, 10002, 10050, 10063, 10000)) {
                        nostrService.processRelayMessage(message, relayUrl)
                        return
                    }

                    // Feed notes → accumulator
                    accumulateEvent(eventObj, message, relayUrl)

                    // Inject mention events into local relay inbox so they persist
                    if (subId == "feed-mentions") {
                        val eventId = eventObj["id"]?.jsonPrimitive?.contentOrNull
                        if (eventId != null) {
                            injectExternalEvent(eventObj.toString(), eventId)
                        }
                    }
                }
                "EOSE" -> {
                    if (parsed.size >= 2) {
                        val subId = parsed[1].jsonPrimitive.contentOrNull ?: ""
                        handleFeedEOSE(subId, relayUrl)
                    }
                }
                else -> {}
            }
        } catch (e: Exception) {
            Log.w(TAG, "Accumulator parse error: ${e.message}")
        }
    }

    private fun FeedService.accumulateEvent(eventObj: JsonObject, rawMessage: String, relayUrl: String) {
        val id = eventObj["id"]?.jsonPrimitive?.contentOrNull ?: return
        val pubkey = eventObj["pubkey"]?.jsonPrimitive?.contentOrNull ?: return
        val kind = eventObj["kind"]?.jsonPrimitive?.intOrNull ?: return
        val content = eventObj["content"]?.jsonPrimitive?.contentOrNull ?: ""
        val createdAt = eventObj["created_at"]?.jsonPrimitive?.longOrNull ?: return

        val tags = eventObj["tags"]?.jsonArray?.map { tagArr ->
            tagArr.jsonArray.map { it.jsonPrimitive.contentOrNull ?: "" }
        } ?: emptyList()

        // Dedup. On overflow, rebuild from currently retained notes (iOS parity)
        // instead of FIFO-evicting — keeps the set aligned with what's displayed.
        val isNew = seenIdsLock.withLock {
            val added = seenIds.add(id)
            if (added && seenIds.size > MAX_SEEN_IDS) {
                val retained = HashSet<String>(_notes.value.size + _pendingNotes.value.size + 100)
                _notes.value.forEach { retained.add(it.id) }
                _pendingNotes.value.forEach { retained.add(it.id) }
                seenIds.retainAll(retained)
                seenIds.add(id)
            }
            added
        }
        if (!isNew) return

        // Reject future-dated events
        val nowSecs = System.currentTimeMillis() / 1000
        if (createdAt > nowSecs + 60) return

        // Comments on videos, articles and other kinds are not note threads.
        if (kind == NIP10Thread.COMMENT_KIND && !NIP10Thread.isNoteComment(kind, tags)) return

        when (kind) {
            7 -> {
                // Reaction event — track engagement
                val targetId = tags.firstOrNull { it.size >= 2 && it[0] == "e" }?.get(1) ?: return
                accumulator.addReaction(EngagementTracker.ReactionEvent(targetId, pubkey, id, content))
            }
            9735 -> {
                // Zap receipt — track engagement. NIP-57: a receipt is spoofable by
                // anyone who can reach a relay we query, so only trust it once we've
                // confirmed it came from the recipient's own authorized publisher.
                val zapReceipt = ZapService.parseZapReceipt(id, pubkey, content, tags, createdAt)
                if (zapReceipt?.targetEventId != null) {
                    scope.launch {
                        val valid = ZapValidationService.isValidReceipt(
                            receiptPubkey = zapReceipt.receiptPubkey,
                            recipientPubkey = zapReceipt.recipientPubkey,
                            profiles = nostrService.profiles.value,
                        )
                        if (valid) {
                            accumulator.addZap(zapReceipt.targetEventId, zapReceipt.amountSats)
                        }
                    }
                }
            }
            else -> {
                // Content note
                val note = FeedNote.fromEvent(id, pubkey, content, tags, createdAt, kind)
                if (note.isNoise) return

                accumulator.addNote(note)

                // Cache raw event JSON. Slice it out of the already-parsed relay
                // message instead of re-serializing eventObj (toString walks the
                // whole JSON tree + escapes strings — a real per-note cost under a
                // streaming flood). message is ["EVENT",sub,{event}] so the event
                // object is from the first '{' to the last '}'.
                val firstBrace = rawMessage.indexOf('{')
                val lastBrace = rawMessage.lastIndexOf('}')
                val rawJson = if (firstBrace in 0 until lastBrace) {
                    rawMessage.substring(firstBrace, lastBrace + 1)
                } else {
                    eventObj.toString()
                }
                rawEventCache[id] = rawJson
                if (rawEventCache.size > MAX_RAW_EVENT_CACHE) {
                    val keysToRemove = rawEventCache.keys.take(rawEventCache.size - MAX_RAW_EVENT_CACHE)
                    keysToRemove.forEach { rawEventCache.remove(it) }
                }
                // Profile fetch is issued once per flush for all new authors in
                // deliverBackgroundBatch() — no need for a per-event call here
                // (each one takes a lock + runs the shouldFetch checks).
            }
        }

        scheduleBackgroundFlush()
    }

    private fun FeedService.scheduleBackgroundFlush() {
        flushLock.withLock {
            if (flushScheduled) return
            flushScheduled = true
        }

        val interval = if (isGlobalLikeMode() || _mediaFeedMode.value == MediaFeedMode.GLOBAL) {
            FLUSH_INTERVAL_GLOBAL_MS
        } else {
            FLUSH_INTERVAL_STANDARD_MS
        }

        scope.launch {
            delay(interval)
            // Inserting rows mid-fling makes the list re-measure and shift under
            // the finger, which on a low-RAM phone is a dropped frame per batch
            // (Global flushes every 50 ms). Events keep accumulating meanwhile
            // and land together when the list stops.
            withTimeoutOrNull(SCROLL_FLUSH_HOLD_MS) { feedScrolling.first { !it } }
            flushLock.withLock { flushScheduled = false }
            flushAccumulator()
        }
    }

    internal fun FeedService.flushAccumulator() {
        val batch = accumulator.drain()
        if (batch.notes.isEmpty() && batch.reactions.isEmpty() && batch.zaps.isEmpty()) return

        scope.launch(Dispatchers.Main.immediate) {
            deliverBackgroundBatch(batch)
        }
    }

    private fun FeedService.deliverBackgroundBatch(batch: BackgroundAccumulator.Snapshot) {
        // Apply notes.
        //
        // iOS-parity auto-reveal: brand-new top-of-feed posts are NOT inserted
        // directly (that would push the feed under the user's scroll, hiding the
        // new note above the keyed LazyColumn's anchor). Instead they are staged
        // as pendingNotes. FeedScreen auto-applies them (and snaps to top) when
        // the user is already at the top with auto-load on, or surfaces the
        // "New Posts" pill otherwise.
        //
        // Older notes (pagination) and replies always insert directly so they
        // slot into place without a pill. During the initial load — or whenever
        // the feed is empty — everything inserts directly so the feed populates
        // instead of hiding behind a pill.
        if (batch.notes.isNotEmpty()) {
            if (isInitialLoad || _notes.value.isEmpty()) {
                insertNotesDirect(batch.notes)
            } else {
                // 60s clock-drift grace, matching iOS flushNoteBuffer.
                val newestMillis = _notes.value.first().createdAt.time
                val driftThreshold = newestMillis - 60_000L
                val toPending = ArrayList<FeedNote>()
                val toAdd = ArrayList<FeedNote>()
                for (note in batch.notes) {
                    if (note.createdAt.time > driftThreshold && !note.isReply) {
                        toPending.add(note)
                    } else {
                        toAdd.add(note)
                    }
                }
                if (toAdd.isNotEmpty()) insertNotesDirect(toAdd)
                // The mention REQ keeps running under Polls (it doubles as
                // notifications); its notes must not count in the Polls pill.
                if (_feedMode.value == FeedMode.POLLS) toPending.retainAll { it.kind == NIP88Poll.KIND }
                if (toPending.isNotEmpty()) stagePendingNotes(toPending)
            }
        }

        // Apply engagement
        if (batch.reactions.isNotEmpty() || batch.zaps.isNotEmpty()) {
            pendingEngagement.add(batch)
            startMergeWorker()
        }

        // Fetch missing profiles for new note authors
        val newPubkeys = batch.notes.map { it.pubkey }.distinct()
        nostrService.fetchMissingProfiles(newPubkeys)

        recomputeFilteredNotes()
    }

    /**
     * Insert notes directly into the visible feed, re-sorting newest-first and capping size.
     *
     * The merge copies, dedupes and sorts the whole feed (up to MAX_FEED_NOTES),
     * so it runs on [processingDispatcher]; doing it on Main cost a frame per
     * relay batch. One worker does every merge: batches that land while it is
     * busy are folded into its next pass instead of racing it (on Global a
     * batch lands every 50 ms, and parallel merges kept invalidating each
     * other). Every other writer of [_notes] runs on Main, so a pass publishes
     * there only if [_notes] is still the list it was built from — otherwise
     * it is rebuilt from the newer one rather than overwriting it.
     *
     * [pendingInserts], [pendingEngagement] and [mergeJob] are Main-confined.
     */
    private fun FeedService.insertNotesDirect(newNotes: List<FeedNote>) {
        pendingInserts.addAll(newNotes)
        startMergeWorker()
    }

    private fun FeedService.startMergeWorker() {
        if (mergeJob?.isActive == true) return
        mergeJob = scope.launch {
            while (pendingInserts.isNotEmpty() || pendingEngagement.isNotEmpty()) {
                if (pendingInserts.isNotEmpty()) {
                    val newNotes = pendingInserts.toList()
                    pendingInserts.clear()
                    while (true) {
                        val base = _notes.value
                        val merged = withContext(processingDispatcher) {
                            val m = (base + newNotes)
                                .distinctBy { it.id } // LazyColumn keys on id — duplicates crash the UI
                                .sortedByDescending { it.createdAt }
                            if (m.size > MAX_FEED_NOTES) m.take(MAX_FEED_NOTES) else m
                        }
                        if (_notes.value === base) {
                            _notes.value = merged
                            break
                        }
                    }
                }
                // After the notes, so the stats trim sees the notes this
                // same batch brought.
                if (pendingEngagement.isNotEmpty()) {
                    val batches = pendingEngagement.toList()
                    pendingEngagement.clear()
                    applyEngagement(batches)
                }
            }
            recomputeFilteredNotes()
        }
    }

    /** Drop queued merges, e.g. when the feed is cleared for another account. */
    internal fun FeedService.cancelMergeWorker() {
        mergeJob?.cancel()
        mergeJob = null
        pendingInserts.clear()
        pendingEngagement.clear()
    }

    /** Fold batches' reactions and zaps into [_noteStats]; same off-Main pattern as [insertNotesDirect]. */
    private suspend fun FeedService.applyEngagement(batches: List<BackgroundAccumulator.Snapshot>) {
        applySelfReactions(batches.flatMap { it.reactions })
        val retracted = retractedReactionIds
        while (true) {
            val base = _noteStats.value
            val notesNow = _notes.value
            val parentIds = _parentNotesCache.value.keys
            val updated = withContext(processingDispatcher) {
                val currentStats = base.toMutableMap()
                for (batch in batches) {
                    for (rx in batch.reactions) {
                        // Removed by this account; relays may still serve it.
                        if (rx.eventId in retracted) continue
                        val targetId = rx.targetId
                        val existing = currentStats[targetId] ?: NoteStats()
                        currentStats[targetId] = existing.copy(
                            reactionCount = existing.reactionCount + 1
                        )
                    }
                    for ((targetId, amount) in batch.zaps) {
                        val existing = currentStats[targetId] ?: NoteStats()
                        currentStats[targetId] = existing.copy(
                            zapCount = existing.zapCount + 1,
                            zapAmountSats = existing.zapAmountSats + amount
                        )
                    }
                }
                // Trim stats to only cover notes still in memory
                if (currentStats.size > MAX_FEED_NOTES) {
                    val activeIds = notesNow.mapTo(HashSet()) { it.id } + parentIds
                    currentStats.keys.retainAll(activeIds)
                }
                currentStats
            }
            if (_noteStats.value === base) {
                _noteStats.value = updated
                return
            }
        }
    }

    /**
     * Stage brand-new top-of-feed notes as pending (the "New Posts" buffer).
     * Deduplicated by id, sorted newest-first, capped at MAX_PENDING_NOTES.
     */
    private fun FeedService.stagePendingNotes(newNotes: List<FeedNote>) {
        val unique = LinkedHashMap<String, FeedNote>()
        for (note in _pendingNotes.value) unique[note.id] = note
        for (note in newNotes) unique.putIfAbsent(note.id, note)
        var sorted = unique.values.sortedByDescending { it.createdAt }
        if (sorted.size > MAX_PENDING_NOTES) sorted = sorted.take(MAX_PENDING_NOTES)
        _pendingNotes.value = sorted
    }
