package com.nostrvault.service

import com.nostrvault.relay.HavenBridge
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
        /** Keep only events whose id and signature check out. */
        verifySignatures: Boolean = false,
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

                                if ((acceptKinds == null || kind in acceptKinds) &&
                                    (!verifySignatures || HavenBridge.verifyEvent(ev.toString()))
                                ) {
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

    /**
     * Fetch a whole thread for the note-detail view. Queries the entire subtree
     * by NIP-10 thread [rootId] (so siblings and the wider thread appear when a
     * mid-thread reply is opened, not just direct replies to the opened note),
     * the [focusedId]'s own direct replies, and fetches the root plus any
     * [ancestorIds] by id so missing parents are filled in from the network.
     * Mirrors iOS NoteDetailView (fetchReplies by root + fetchParents by ids).
     */
    internal fun NostrService.threadQuery(
        rootId: String,
        focusedId: String,
        ancestorIds: List<String>,
        rootCoordinate: String? = null,
        onRawEvent: ((String, String) -> Unit)? = null,
        onResult: (List<FeedNote>) -> Unit,
    ) {
        fun jsonArr(values: List<String>) =
            values.distinct().joinToString(",") { "\"$it\"" }
        // #e by root + focused note + all ancestors so legacy replies that only
        // tag their direct parent (not the thread root) are still fetched.
        val eIds = (listOf(rootId, focusedId) + ancestorIds).distinct()
        // NIP-22 comments (1111) tag their direct parent in lowercase e too.
        val eFilter = """{"kinds":[1,${NIP10Thread.COMMENT_KIND}],"#e":[${jsonArr(eIds)}],"limit":200}"""
        // NIP-22 comments name the thread root in uppercase E, so one filter
        // reaches them at any depth (iOS NoteDetailView commentsFilter).
        val commentsFilter = """{"kinds":[${NIP10Thread.COMMENT_KIND}],"#E":[${jsonArr(listOf(rootId))}],"limit":150}"""
        // Root note itself + ancestors are not replies, so fetch by id. An
        // ancestor of a comment is usually itself a comment.
        // No kinds: a picture, video, article or poll can root a thread, and
        // an id names one event whatever its kind (iOS fetchParents).
        val idValues = (listOf(rootId) + ancestorIds).distinct()
        val idFilter = """{"ids":[${jsonArr(idValues)}]}"""
        // Comments on an addressable or replaceable root name it by A; an
        // edited article has a new event id, so #E alone misses them.
        val filters = mutableListOf(eFilter, commentsFilter, idFilter)
        if (rootCoordinate != null) {
            filters.add("""{"kinds":[${NIP10Thread.COMMENT_KIND}],"#A":[${jsonArr(listOf(rootCoordinate))}],"limit":150}""")
        }
        // Replies are notes and comments; the root and parents asked for by
        // id are whatever kind they are.
        val byId = idValues.toSet()
        queryDetailRelays(filters, onRawEvent, acceptKinds = null) { notes ->
            onResult(notes.filter { it.kind == 1 || it.kind == NIP10Thread.COMMENT_KIND || it.id in byId })
        }
    }

    /**
     * Responses to [rootId] that aren't thread rows (spec "below the fold"):
     * quotes of any kind (#q) plus highlights (9802) and voice replies (1244).
     * The caller decides which of these are quotes rather than replies.
     *
     * [rootCoordinate] is the root's address when it is addressable: an
     * article's highlights name it by its `a` coordinate, not by this
     * version's id, so `#e` alone never finds them (iOS #189).
     */
    internal fun NostrService.otherResponsesQuery(rootId: String, rootCoordinate: String? = null, onResult: (List<FeedNote>) -> Unit) {
        val filters = mutableListOf(
            """{"#q":["$rootId"],"limit":50}""",
            """{"kinds":[9802,1244],"#e":["$rootId"],"limit":50}""",
        )
        if (rootCoordinate != null) {
            filters.add("""{"kinds":[9802,1244],"#a":[${JsonPrimitive(rootCoordinate)}],"limit":50}""")
        }
        // Shown as "<name> highlighted this": it must really be theirs, so a
        // relay can't put words in someone's mouth (iOS handleReplyMessage).
        queryDetailRelays(
            filters,
            onRawEvent = null,
            onEose = onResult,
            acceptKinds = null,
            verifySignatures = true,
        )
    }
