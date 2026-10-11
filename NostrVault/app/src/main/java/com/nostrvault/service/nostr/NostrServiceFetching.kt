package com.nostrvault.service

import com.nostrvault.data.model.FeedNote
import com.nostrvault.data.model.NIP10Thread
import kotlinx.coroutines.*
import kotlinx.coroutines.flow.*
import kotlinx.serialization.json.*
import java.util.UUID
import java.util.concurrent.ConcurrentHashMap
import com.nostrvault.service.NostrService.Companion.TEMP_CLIENT_DISCONNECT_MS

    // ══════════════════════════════════════════════════════════════════
    // Profile notes + replies fetching
    // ══════════════════════════════════════════════════════════════════

    /**
     * Fetch kind:1 notes authored by [pubkey] from known relays.
     * Results are delivered via [onResult] callback.
     */
    fun NostrService.fetchProfileNotes(pubkey: String, onResult: (List<FeedNote>) -> Unit) {
        val config = configStore.config.value
        val relayUrls = buildList {
            config.nostrURL?.let { add(it) }
            // A tapped profile's notes live on the author's outbox / public relays,
            // not just our local + inbox relays. The local relay only holds the
            // owner's notes, and config.inboxRelays can be null/empty at runtime —
            // leaving the query with nowhere to find a stranger's notes. Use the
            // fallback-backed active* accessors and mirror queryDetailRelays so
            // strangers' notes are actually found (matches iOS ProfileView).
            addAll(config.activeInboxRelays)
            addAll(config.activeFeedRelays)
            addAll(config.activeBlastrRelays)
        }.distinct().take(8)
        if (relayUrls.isEmpty()) { onResult(emptyList()); return }

        val subId = "profile-${UUID.randomUUID().toString().take(8)}"
        val collected = java.util.concurrent.ConcurrentHashMap<String, FeedNote>()

        for (relayUrl in relayUrls) {
            scope.launch(Dispatchers.IO) {
                try {
                    // The pool subscribes to a socket's messages before it
                    // connects, so an early EVENT/EOSE is not dropped.
                    val filter = """{"kinds":[1],"authors":["$pubkey"],"limit":50}"""
                    lookupPool.query(relayUrl, subId, listOf(filter), TEMP_CLIENT_DISCONNECT_MS) { msg ->
                        try {
                            val parsed = json.parseToJsonElement(msg).jsonArray
                            // EOSE frames are ["EOSE", subId] (size 2). A < 3
                            // guard dropped them before the EOSE handler, so the
                            // collected notes were never delivered via onResult.
                            if (parsed.size < 2) return@query
                            val type = parsed[0].jsonPrimitive.contentOrNull ?: return@query
                            val sid = parsed[1].jsonPrimitive.contentOrNull ?: return@query
                            if (type == "EVENT" && sid == subId) {
                                val ev = parsed[2].jsonObject
                                val id = ev["id"]?.jsonPrimitive?.contentOrNull ?: return@query
                                val pk = ev["pubkey"]?.jsonPrimitive?.contentOrNull ?: return@query
                                val content = ev["content"]?.jsonPrimitive?.contentOrNull ?: ""
                                val createdAt = ev["created_at"]?.jsonPrimitive?.longOrNull ?: 0L
                                val kind = ev["kind"]?.jsonPrimitive?.intOrNull ?: return@query
                                val tags: List<List<String>> = try {
                                    ev["tags"]?.jsonArray?.map { t -> t.jsonArray.map { it.jsonPrimitive.content } } ?: emptyList()
                                } catch (_: Exception) { emptyList() }

                                if (kind == 1) {
                                    collected[id] = FeedNote.fromEvent(id, pk, content, tags, createdAt, kind)
                                }
                            }
                            if (type == "EOSE" && sid == subId) {
                                onResult(collected.values.sortedByDescending { it.createdAt })
                            }
                        } catch (_: Exception) {}
                    }
                } catch (_: Exception) {}
            }
        }
    }

    /**
     * Shared one-shot query for the note-detail view: temporary clients to
     * the detail relay set (local + inbox + feed/blastr, public fallback),
     * collecting kind-1 events. [onEose] fires on every relay's EOSE with
     * the cumulative sorted list, so callers must merge idempotently.
     * [onRawEvent] receives each raw event JSON (id, json) for raw-event
     * caching (broadcast needs the exact signed JSON).
     */
    internal fun NostrService.queryDetailRelays(
        filters: List<String>,
        onRawEvent: ((String, String) -> Unit)? = null,
        /** Kinds to keep; null keeps every kind. */
        acceptKinds: Set<Int>? = setOf(1, NIP10Thread.COMMENT_KIND),
        onEose: (List<FeedNote>) -> Unit,
    ) {
        val config = configStore.config.value
        val relayUrls = buildList {
            config.nostrURL?.let { add(it) }
            config.inboxRelays?.let { addAll(it) }
            // Replies from other users propagate to feed/blastr relays, not just
            // the local + inbox relays. Mirror iOS (NoteDetailView) which queries
            // external feed relays so strangers' replies are actually found.
            addAll(config.readRelays)
            addAll(config.writeRelays)
        }.distinct().take(8)
        if (relayUrls.isEmpty()) { onEose(emptyList()); return }

        val subId = "replies-${UUID.randomUUID().toString().take(8)}"
        val collected = java.util.concurrent.ConcurrentHashMap<String, FeedNote>()

        for (relayUrl in relayUrls) {
            scope.launch(Dispatchers.IO) {
                try {
                    lookupPool.query(relayUrl, subId, filters, TEMP_CLIENT_DISCONNECT_MS) { msg ->
                        try {
                            val parsed = json.parseToJsonElement(msg).jsonArray
                            // EOSE is ["EOSE", subId] (size 2); a < 3 guard dropped
                            // it so onEose never fired and replies/thread results
                            // were never delivered. Same bug as fetchProfileNotes.
                            if (parsed.size < 2) return@query
                            val type = parsed[0].jsonPrimitive.contentOrNull ?: return@query
                            val sid = parsed[1].jsonPrimitive.contentOrNull ?: return@query
                            if (type == "EVENT" && sid == subId) {
                                val ev = parsed[2].jsonObject
                                val id = ev["id"]?.jsonPrimitive?.contentOrNull ?: return@query
                                val pk = ev["pubkey"]?.jsonPrimitive?.contentOrNull ?: return@query
                                val content = ev["content"]?.jsonPrimitive?.contentOrNull ?: ""
                                val createdAt = ev["created_at"]?.jsonPrimitive?.longOrNull ?: 0L
                                val kind = ev["kind"]?.jsonPrimitive?.intOrNull ?: return@query
                                val tags: List<List<String>> = try {
                                    ev["tags"]?.jsonArray?.map { t -> t.jsonArray.map { it.jsonPrimitive.content } } ?: emptyList()
                                } catch (_: Exception) { emptyList() }

                                if (acceptKinds == null || kind in acceptKinds) {
                                    collected[id] = FeedNote.fromEvent(id, pk, content, tags, createdAt, kind)
                                    onRawEvent?.invoke(id, ev.toString())
                                }
                            }
                            if (type == "EOSE" && sid == subId) {
                                onEose(collected.values.sortedBy { it.createdAt })
                            }
                        } catch (_: Exception) {}
                    }
                } catch (_: Exception) {}
            }
        }
    }
