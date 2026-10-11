package com.nostrvault.service

import com.nostrvault.data.model.*
import com.nostrvault.data.remote.LookupSocketPool
import com.nostrvault.util.ZapAmount
import kotlinx.coroutines.*
import kotlinx.serialization.json.*
import java.util.UUID
import java.util.concurrent.ConcurrentHashMap
import com.nostrvault.service.FeedService.Companion.NOTE_FETCH_TIMEOUT_MS

    // ══════════════════════════════════════════════════════════════════
    // Engagement details: the note screen's likes, zaps and reposts
    // ══════════════════════════════════════════════════════════════════

    /** A zap receipt with the pubkeys its NIP-57 check needs. */
    internal class PendingZap(val detail: ZapDetail, val receiptPubkey: String, val recipientPubkey: String?)

    /** The zapped pubkey: the receipt's `p` tag. */
    private fun recipientOf(tags: List<List<String>>): String? =
        tags.firstOrNull { it.size >= 2 && it[0] == "p" }?.get(1)

    /**
     * Receipts published by the recipient's own zap provider. Anyone can
     * publish a 9735 with any amount, so unchecked totals were fakeable; one
     * with no `p` tag names nobody and is dropped (iOS ThreadEngagement).
     */
    internal suspend fun FeedService.validZaps(pending: List<PendingZap>): List<ZapDetail> {
        val profiles = nostrService.profiles.value
        // Side by side: an uncached recipient is an LNURL round trip.
        return coroutineScope {
            pending.map { zap ->
                async {
                    val recipient = zap.recipientPubkey ?: return@async null
                    zap.detail.takeIf { ZapValidationService.isValidReceipt(zap.receiptPubkey, recipient, profiles) }
                }
            }.awaitAll().filterNotNull()
        }
    }

    /** Fetch detailed engagement data (who reacted, zapped, reposted) for a single note. */
    internal fun FeedService.loadEngagementDetails(noteId: String, callback: (EngagementDetails) -> Unit) {
        scope.launch(Dispatchers.IO) {
            val config = configStore.config.value
            val relayUrls = buildList {
                config.nostrURL?.let { add(it) }
                config.localInboxURL?.let { add(it) }
                config.inboxRelays?.let { addAll(it.take(1)) }
            }.distinct()

            val seenIds = mutableSetOf<String>()
            val reactions = mutableListOf<ReactionDetail>()
            val zaps = mutableListOf<PendingZap>()
            val reposts = mutableListOf<RepostDetail>()

            for (relayUrl in relayUrls) {
                val subId = "eng-${UUID.randomUUID().toString().take(8)}"
                val filter = """{"kinds":[6,7,9735],"#e":["$noteId"]}"""
                lookupPool.query(relayUrl, subId, listOf(filter), NOTE_FETCH_TIMEOUT_MS) { msg ->
                    try {
                        val parsed = json.parseToJsonElement(msg).jsonArray
                        if (parsed.size >= 3 && parsed[0].jsonPrimitive.contentOrNull == "EVENT") {
                            val eventObj = parsed[2].jsonObject
                            val id = eventObj["id"]?.jsonPrimitive?.contentOrNull ?: return@query
                            if (!seenIds.add(id)) return@query
                            val kind = eventObj["kind"]?.jsonPrimitive?.intOrNull ?: return@query
                            val pubkey = eventObj["pubkey"]?.jsonPrimitive?.contentOrNull ?: return@query
                            val content = eventObj["content"]?.jsonPrimitive?.contentOrNull ?: ""
                            val tags = eventObj["tags"]?.jsonArray?.map { t ->
                                t.jsonArray.map { it.jsonPrimitive.contentOrNull ?: "" }
                            } ?: emptyList()

                            when (kind) {
                                7 -> {
                                    val emoji = if (content == "+" || content.isBlank()) "\u2764\uFE0F" else content
                                    synchronized(reactions) { reactions.add(ReactionDetail(id, pubkey, emoji)) }
                                }
                                9735 -> {
                                    val descTag = tags.firstOrNull { it.size >= 2 && it[0] == "description" }?.get(1)
                                    var zapperPubkey = pubkey
                                    var comment = ""
                                    if (descTag != null) {
                                        try {
                                            val zapReq = json.parseToJsonElement(descTag).jsonObject
                                            zapperPubkey = zapReq["pubkey"]?.jsonPrimitive?.contentOrNull ?: pubkey
                                            comment = zapReq["content"]?.jsonPrimitive?.contentOrNull ?: ""
                                        } catch (_: Exception) {}
                                    }
                                    // The request's `amount` tag is optional (NIP-57); the paid invoice is not.
                                    val amountSats = ZapAmount.sats(tags)
                                    val zap = PendingZap(ZapDetail(id, zapperPubkey, amountSats, comment), pubkey, recipientOf(tags))
                                    synchronized(zaps) { zaps.add(zap) }
                                }
                                6 -> {
                                    synchronized(reposts) { reposts.add(RepostDetail(id, pubkey)) }
                                }
                            }
                        }
                    } catch (_: Exception) {}
                }
            }

            val validZaps = validZaps(zaps)
            val allPubkeys = (reactions.map { it.pubkey } + validZaps.map { it.zapperPubkey } + reposts.map { it.pubkey }).distinct()
            if (allPubkeys.isNotEmpty()) {
                nostrService.fetchMissingProfiles(allPubkeys)
            }

            val result = EngagementDetails(
                reactions = reactions.toList(),
                zaps = validZaps.sortedByDescending { it.amountSats },
                reposts = reposts.distinctBy { it.pubkey },
            )
            withContext(Dispatchers.Main.immediate) { callback(result) }
        }
    }

    /**
     * Reactions, zaps and reposts for every note in a thread (Thread Stats).
     * The thread is split into batches of [ThreadEngagementQuery.BATCH_SIZE]
     * notes, each its own REQ with its own limit, sent one after another on
     * each relay, so one busy note can't use up the budget of the others
     * (iOS #325). Relays are asked side by side.
     */
    internal fun FeedService.loadThreadEngagement(noteIds: List<String>, callback: (Map<String, EngagementDetails>) -> Unit) {
        if (noteIds.isEmpty()) { callback(emptyMap()); return }
        scope.launch(Dispatchers.IO) {
            val config = configStore.config.value
            // The account's relay and the feed relays, as iOS asks.
            val relayUrls = buildList {
                config.nostrURL?.let { add(it) }
                addAll(config.readRelays)
            }.distinctBy { LookupSocketPool.relayKey(it) }

            val seenIds = ConcurrentHashMap.newKeySet<String>()
            val noteIdSet = noteIds.toSet()
            val perNote = ConcurrentHashMap<String, MutableList<Any>>()
            val requests = ThreadEngagementQuery.requests(
                noteIdSet, "thr-${UUID.randomUUID().toString().take(6)}",
            )

            withTimeoutOrNull(ThreadEngagementQuery.timeoutMs(requests.size)) {
                relayUrls.map { relayUrl ->
                    async {
                        for (request in requests) {
                            val outcome = lookupPool.query(relayUrl, request.subscriptionId, listOf(request.filter), NOTE_FETCH_TIMEOUT_MS) { msg ->
                                try {
                                    val parsed = json.parseToJsonElement(msg).jsonArray
                                    if (parsed.size >= 3 && parsed[0].jsonPrimitive.contentOrNull == "EVENT") {
                                        val eventObj = parsed[2].jsonObject
                                        val id = eventObj["id"]?.jsonPrimitive?.contentOrNull ?: return@query
                                        if (!seenIds.add(id)) return@query
                                        val kind = eventObj["kind"]?.jsonPrimitive?.intOrNull ?: return@query
                                        val pubkey = eventObj["pubkey"]?.jsonPrimitive?.contentOrNull ?: return@query
                                        val content = eventObj["content"]?.jsonPrimitive?.contentOrNull ?: ""
                                        val tags = eventObj["tags"]?.jsonArray?.map { t ->
                                            t.jsonArray.map { it.jsonPrimitive.contentOrNull ?: "" }
                                        } ?: emptyList()

                                        val targetNoteId = ThreadEngagementQuery.targetNoteId(tags, noteIdSet) ?: return@query

                                        val detail: Any = when (kind) {
                                            7 -> {
                                                val emoji = if (content == "+" || content.isBlank()) "\u2764\uFE0F" else content
                                                ReactionDetail(id, pubkey, emoji)
                                            }
                                            9735 -> {
                                                val descTag = tags.firstOrNull { it.size >= 2 && it[0] == "description" }?.get(1)
                                                var zapperPubkey = pubkey
                                                var comment = ""
                                                if (descTag != null) {
                                                    try {
                                                        val zapReq = json.parseToJsonElement(descTag).jsonObject
                                                        zapperPubkey = zapReq["pubkey"]?.jsonPrimitive?.contentOrNull ?: pubkey
                                                        comment = zapReq["content"]?.jsonPrimitive?.contentOrNull ?: ""
                                                    } catch (_: Exception) {}
                                                }
                                                // The request's `amount` tag is optional (NIP-57); the paid invoice is not.
                                                val amountSats = ZapAmount.sats(tags)
                                                PendingZap(ZapDetail(id, zapperPubkey, amountSats, comment), pubkey, recipientOf(tags))
                                            }
                                            6 -> RepostDetail(id, pubkey)
                                            else -> return@query
                                        }
                                        perNote.computeIfAbsent(targetNoteId) { java.util.Collections.synchronizedList(mutableListOf()) }.add(detail)
                                    }
                                } catch (_: Exception) {}
                            }
                            // A relay that refuses the socket refuses every batch.
                            if (outcome == LookupSocketPool.Outcome.SKIPPED || outcome == LookupSocketPool.Outcome.FAILED) break
                        }
                    }
                }.awaitAll()
            }

            val result = perNote.mapValues { (_, details) ->
                EngagementDetails(
                    reactions = details.filterIsInstance<ReactionDetail>(),
                    zaps = validZaps(details.filterIsInstance<PendingZap>()).sortedByDescending { it.amountSats },
                    reposts = details.filterIsInstance<RepostDetail>().distinctBy { it.pubkey },
                )
            }
            withContext(Dispatchers.Main.immediate) { callback(result) }
        }
    }
