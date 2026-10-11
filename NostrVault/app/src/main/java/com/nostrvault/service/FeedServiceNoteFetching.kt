package com.nostrvault.service

import com.nostrvault.data.model.*
import com.nostrvault.data.remote.LookupSocketPool
import com.nostrvault.data.remote.WebSocketClient
import com.nostrvault.relay.HavenBridge
import kotlinx.coroutines.*
import kotlinx.coroutines.flow.*
import kotlinx.serialization.json.*
import java.util.UUID
import java.util.concurrent.ConcurrentHashMap
import com.nostrvault.service.FeedService.Companion.NOTE_FETCH_TIMEOUT_MS
import com.nostrvault.service.FeedService.Companion.FALLBACK_NOTE_RELAYS
import com.nostrvault.service.FeedService.Companion.PARENT_CACHE_MAX
import com.nostrvault.service.FeedService.Companion.PARENT_CACHE_TRIM_TO

    /**
     * Copies the notes among [ids] that are already in the feed into the
     * parent cache and clears any "unavailable" mark on them. Matches on the
     * note's own id only: a repost is indexed under its original's id too,
     * and a row must not show the repost as the parent. Returns the ids found.
     */
    internal fun FeedService.adoptFeedNotes(ids: List<String>): Set<String> {
        val index = noteIndex()
        val notes = _notes.value
        val found = ids.mapNotNull { id -> feedNoteWithOwnId(index, notes, id) }
            .filter { !_parentNotesCache.value.containsKey(it.id) }
        if (found.isEmpty()) return emptySet()
        _parentNotesCache.update { cache -> cache + found.associateBy { it.id } }
        val foundIds = found.mapTo(HashSet()) { it.id }
        foundIds.forEach { unavailableSince.remove(it) }
        if (_unavailableNoteIds.value.any { it in foundIds }) _unavailableNoteIds.update { it - foundIds }
        return foundIds
    }

    /**
     * Two passes, mirroring iOS FeedService.flushNoteFetchRequests:
     *  1. your relays (local, inbox, feed, blastr) for every id, plus each
     *     id's relay hint and its author's write relays;
     *  2. for what's still missing, [FALLBACK_NOTE_RELAYS] and a bigger hint
     *     budget, since the authors' relay lists have usually arrived by then.
     * Then anything still missing is marked unavailable.
     *
     * Measured 2026-10-01 (iOS logic, Logen's Following tab): this used to ask
     * only the local relay and two inbox relays. The wider set took the miss
     * rate from 61% to about 12%.
     */
    internal suspend fun FeedService.lookUpNotes(chunk: List<String>) {
        try {
            lookUpNotesInPasses(chunk)
        } finally {
            noteFetchInFlight.removeAll(chunk.toSet())
        }
    }

    private suspend fun FeedService.lookUpNotesInPasses(chunk: List<String>) {
        val config = configStore.config.value
        val ownRelays = buildList {
            config.nostrURL?.let { add(it) }
            config.inboxRelays?.let { addAll(it) }
            addAll(config.activeFeedRelays)
            addAll(config.activeBlastrRelays)
        }.distinct()

        // Arrivals are tracked here, not read back from the cache: the cache's
        // over-500 trim drops notes the feed doesn't reference (one opened
        // from Search, say), and those must not then be called unavailable.
        val arrived = ConcurrentHashMap.newKeySet<String>()
        requestRelayListsFor(chunk)
        val firstHints = hintRelays(chunk, ownRelays, cap = 12)
        requestNotes(ownRelays.associateWith { chunk } + firstHints, arrived)

        val stillMissing = chunk.filter { it !in arrived && !_parentNotesCache.value.containsKey(it) }
        if (stillMissing.isNotEmpty()) {
            val asked = ownRelays + firstHints.keys
            val askedKeys = asked.map { normalizeRelay(it) }.toSet()
            val fallbacks = FALLBACK_NOTE_RELAYS.filter { normalizeRelay(it) !in askedKeys }
            val hints = hintRelays(stillMissing, asked + fallbacks, cap = 24)
            requestNotes(fallbacks.associateWith { stillMissing } + hints, arrived)
        }

        val givenUp = chunk.filter { it !in arrived && !_parentNotesCache.value.containsKey(it) }.toSet()
        if (givenUp.isNotEmpty()) {
            val now = System.currentTimeMillis()
            givenUp.forEach { unavailableSince[it] = now }
            _unavailableNoteIds.update { it + givenUp }
        }
    }

    /**
     * Each id's relay hint and its author's write relays, keeping the relays
     * that cover the most ids. Keeping them in arrival order let the first
     * ids fill the cap, so later ids got no hint relay at all.
     */
    private fun FeedService.hintRelays(ids: List<String>, exclude: Collection<String>, cap: Int): Map<String, List<String>> {
        val skip = exclude.map { normalizeRelay(it) }.toSet()
        // Keyed by the normalized form to merge duplicates, but the request
        // goes to the URL as written: lowercasing would change a path.
        val urlForKey = mutableMapOf<String, String>()
        val byRelay = mutableMapOf<String, MutableList<String>>()
        for (id in ids) {
            val (hint, author) = referenceHints(id)
            val urls = buildList {
                hint?.let { add(it) }
                author?.let { a -> nostrService.outboxRelays.value[a]?.take(3)?.let { addAll(it) } }
            }
            for (url in urls) {
                val key = normalizeRelay(url)
                if (key in skip) continue
                urlForKey.getOrPut(key) { url.trim() }
                byRelay.getOrPut(key) { mutableListOf() }.add(id)
            }
        }
        return byRelay.entries
            .sortedByDescending { it.value.size }
            .take(cap)
            .associate { urlForKey.getValue(it.key) to it.value.distinct() }
    }

    /** The relay hint and author a note in the feed gives for the id it references. */
    private fun FeedService.referenceHints(id: String): Pair<String?, String?> {
        for (note in _notes.value) {
            val tag = note.tags.firstOrNull { it.size >= 2 && (it[0] == "e" || it[0] == "q") && it[1] == id } ?: continue
            val hint = tag.getOrNull(2)?.takeIf { it.startsWith("wss://") || it.startsWith("ws://") }
            val author = tag.getOrNull(4)?.takeIf { it.length == 64 }
                ?: tag.getOrNull(3)?.takeIf { tag[0] == "q" && it.length == 64 }
                ?: if (note.parentEventId == id) note.tags.lastOrNull { it.size >= 2 && it[0] == "p" }?.get(1) else null
            return hint to author
        }
        return null to null
    }

    /** Authors referenced by these ids whose write relays aren't known yet. */
    private fun FeedService.requestRelayListsFor(ids: List<String>) {
        val known = nostrService.outboxRelays.value
        if (relayListRequested.size > 5000) relayListRequested.clear()
        // Once per author: force skips the profile fetch's throttle, and an
        // author with no kind 10002 would otherwise be re-asked every batch.
        val authors = ids.mapNotNull { referenceHints(it).second }
            .filter { it !in known && relayListRequested.add(it) }
            .distinct()
        if (authors.isNotEmpty()) {
            nostrService.fetchMissingProfiles(authors, force = true)
            // The profile fetch asks for kind 0 only; the write relays the
            // hint pass reads come from kind 10002.
            nostrService.fetchRelayLists(authors)
        }
    }

    /** Asks once per author for the NIP-65 lists of [authors] not known yet (iOS requestRelayLists). */
    internal fun FeedService.requestRelayListsForAuthors(authors: Collection<String>) {
        val known = nostrService.outboxRelays.value
        if (relayListRequested.size > 5000) relayListRequested.clear()
        val needed = authors.filter { it !in known && relayListRequested.add(it) }
        if (needed.isNotEmpty()) nostrService.fetchRelayLists(needed)
    }

    private fun FeedService.normalizeRelay(url: String) = url.trim().trimEnd('/').lowercase()

    /**
     * Sends one REQ per relay for its ids and waits until each relay is done
     * (EOSE, CLOSED, refused) or the fetch window runs out.
     *
     * A relay with a live feed socket is asked on that; any other goes through
     * [lookupPool], which keeps one socket per relay across lookups and leaves
     * a relay that refused one (a 429, say) alone for two minutes. Each lookup
     * used to open its own socket to every relay and drop it 8 s later.
     */
    private suspend fun FeedService.requestNotes(requests: Map<String, List<String>>, arrived: MutableSet<String>) {
        if (requests.isEmpty()) return
        coroutineScope {
            for ((relayUrl, ids) in requests) {
                if (ids.isEmpty()) continue
                val idSet = ids.toSet()
                val subId = "pnbatch-${UUID.randomUUID().toString().take(8)}"
                val filter = """{"ids":[${ids.joinToString(",") { "\"$it\"" }}]}"""
                val feedClient = feedClients[relayUrl]
                launch {
                    if (feedClient != null) {
                        askOnFeedClient(feedClient, subId, listOf(filter)) { msg ->
                            handleFetchedNote(msg, idSet)?.let { arrived.add(it) }
                        }
                    } else {
                        lookupPool.query(relayUrl, subId, listOf(filter), NOTE_FETCH_TIMEOUT_MS) { msg ->
                            handleFetchedNote(msg, idSet)?.let { arrived.add(it) }
                        }
                    }
                }
            }
        }
    }

    /**
     * One lookup REQ on a live feed socket: [onMessage] sees every message on
     * it (the feed's own traffic included, so it must match on content) until
     * the relay ends this subscription or the fetch window runs out, then the
     * subscription is CLOSEd.
     */
    internal suspend fun FeedService.askOnFeedClient(
        client: WebSocketClient,
        subId: String,
        filters: List<String>,
        onMessage: suspend (String) -> Unit,
    ) = coroutineScope {
        // Cancelled below. Critical: an un-cancelled collector on a feed
        // client would re-parse every future feed message for the life of
        // the app.
        val ended = CompletableDeferred<Unit>()
        val collector = launch(start = CoroutineStart.UNDISPATCHED) {
            client.messages.collect { msg ->
                onMessage(msg)
                val route = LookupSocketPool.route(msg)
                if (route != null && route.second == subId && (route.first == "EOSE" || route.first == "CLOSED")) {
                    ended.complete(Unit)
                }
            }
        }
        client.send("[\"REQ\",\"$subId\",${filters.joinToString(",")}]")
        try {
            withTimeoutOrNull(NOTE_FETCH_TIMEOUT_MS) { ended.await() }
        } finally {
            collector.cancel()
            client.send("[\"CLOSE\",\"$subId\"]")
        }
    }

    /** Caches a fetched note; returns its id when it was one of [wanted]. */
    private suspend fun FeedService.handleFetchedNote(msg: String, wanted: Set<String>): String? {
        try {
            val parsed = json.parseToJsonElement(msg).jsonArray
            if (parsed.size < 3 || parsed[0].jsonPrimitive.contentOrNull != "EVENT") return null
            val eventObj = parsed[2].jsonObject
            val eventId = eventObj["id"]?.jsonPrimitive?.contentOrNull ?: return null
            if (eventId !in wanted) return null
            if (_parentNotesCache.value.containsKey(eventId)) return eventId
            // These come from relay hints and outboxes named in other people's
            // notes: any of them can send a note under the wanted id and any
            // author's name. Only a valid id hash and signature make it real.
            if (!HavenBridge.verifyEvent(eventObj.toString())) return null
            val pubkey = eventObj["pubkey"]?.jsonPrimitive?.contentOrNull ?: return null
            val content = eventObj["content"]?.jsonPrimitive?.contentOrNull ?: ""
            val tags = eventObj["tags"]?.jsonArray?.map { t -> t.jsonArray.map { it.jsonPrimitive.contentOrNull ?: "" } } ?: emptyList()
            val createdAt = eventObj["created_at"]?.jsonPrimitive?.longOrNull ?: return null
            val kind = eventObj["kind"]?.jsonPrimitive?.intOrNull ?: return null

            val note = FeedNote.fromEvent(eventId, pubkey, content, tags, createdAt, kind)
            // The trim walks every feed note (up to MAX_FEED_NOTES), so it is
            // built here, off Main, and published on Main only if the cache is
            // still the map it was built from. It trims to 400, not 500: at
            // exactly the cap, every later arrival paid the full walk again.
            while (true) {
                val base = _parentNotesCache.value
                var updated = base + (eventId to note)
                if (updated.size > PARENT_CACHE_MAX) {
                    val referencedIds = FeedNote.referencedIds(_notes.value)
                    // Keep the most recently created referenced notes.
                    updated = updated.filter { it.key in referencedIds }
                        .toList()
                        .sortedByDescending { it.second.createdAt }
                        .take(PARENT_CACHE_TRIM_TO)
                        .toMap()
                    // Never trim the note just fetched: it counts as arrived,
                    // so it would not be marked unavailable, and the feed
                    // would ask for it again on its next change.
                    if (eventId !in updated) updated = updated + (eventId to note)
                }
                val published = withContext(Dispatchers.Main.immediate) {
                    if (_parentNotesCache.value !== base) return@withContext false
                    _parentNotesCache.value = updated
                    unavailableSince.remove(eventId)
                    if (eventId in _unavailableNoteIds.value) _unavailableNoteIds.update { it - eventId }
                    true
                }
                if (published) break
            }
            // A reply or bare repost of a blocked author is only recognisable
            // once the post it points at has loaded, so refilter when it's theirs.
            if (pubkey in blockedHexForActiveAccount()) recomputeFilteredNotes()
            return eventId
        } catch (_: Exception) {
            return null
        }
    }

    /**
     * Fetch addressable events by kind + author + `d` tag.
     *
     * One REQ per coordinate rather than one merged filter: a filter carrying
     * several kinds, authors and `d` tags matches every *combination* of them,
     * so two quoted articles by different authors would each pull the other
     * author's article too. The count here is the number of quoted articles on
     * screen, which is small.
     */
    internal fun FeedService.fetchQuotedAddressesBatch(coordinates: List<Pair<String, QuoteRef.Coordinate>>) {
        scope.launch(Dispatchers.IO) {
            val config = configStore.config.value
            val relayUrls = buildList {
                config.nostrURL?.let { add(it) }
                config.inboxRelays?.let { addAll(it) }
                addAll(config.activeFeedRelays)
                addAll(config.activeBlastrRelays)
            }.distinct()

            coroutineScope {
                for (relayUrl in relayUrls) {
                    val feedClient = feedClients[relayUrl]
                    for ((_, coordinate) in coordinates) {
                        val subId = "qaddr-${UUID.randomUUID().toString().take(8)}"
                        val dTagJson = json.encodeToString(JsonPrimitive.serializer(), JsonPrimitive(coordinate.dTag))
                        val filter = """{"kinds":[${coordinate.kind}],"authors":["${coordinate.pubkey}"],"#d":[$dTagJson],"limit":1}"""
                        launch {
                            if (feedClient != null) {
                                askOnFeedClient(feedClient, subId, listOf(filter)) { handleQuotedAddressEvent(it, coordinates) }
                            } else {
                                lookupPool.query(relayUrl, subId, listOf(filter), NOTE_FETCH_TIMEOUT_MS) {
                                    handleQuotedAddressEvent(it, coordinates)
                                }
                            }
                        }
                    }
                }
            }
        }
    }

    private suspend fun FeedService.handleQuotedAddressEvent(msg: String, coordinates: List<Pair<String, QuoteRef.Coordinate>>) {
        try {
            val parsed = json.parseToJsonElement(msg).jsonArray
            if (parsed.size < 3 || parsed[0].jsonPrimitive.contentOrNull != "EVENT") return
            val eventObj = parsed[2].jsonObject
            val eventId = eventObj["id"]?.jsonPrimitive?.contentOrNull ?: return
            val pubkey = eventObj["pubkey"]?.jsonPrimitive?.contentOrNull ?: return
            val content = eventObj["content"]?.jsonPrimitive?.contentOrNull ?: ""
            val tags = eventObj["tags"]?.jsonArray?.map { t -> t.jsonArray.map { it.jsonPrimitive.contentOrNull ?: "" } } ?: emptyList()
            val createdAt = eventObj["created_at"]?.jsonPrimitive?.longOrNull ?: return
            val kind = eventObj["kind"]?.jsonPrimitive?.intOrNull ?: return
            val dTag = tags.firstOrNull { it.size >= 2 && it[0] == "d" }?.get(1) ?: ""

            // Match on what was asked for rather than on the subscription id:
            // these share connections with the live feed, so unrelated events
            // arrive here too.
            val raw = QuoteRef.format(QuoteRef.Coordinate(kind, pubkey, dTag))
            if (coordinates.none { it.first == raw }) return
            // A relay can send anything: only an event signed by the author
            // the address names counts. A `nostr:naddr1…` link opens this.
            if (!HavenBridge.verifyEvent(eventObj.toString())) return

            val note = FeedNote.fromEvent(eventId, pubkey, content, tags, createdAt, kind)
            withContext(Dispatchers.Main.immediate) {
                // An addressable event is replaceable, so a relay may answer
                // with an older revision after a newer one. Keep the newest.
                val existing = _quotedAddressCache.value[raw]
                if (existing == null || existing.createdAt < note.createdAt) {
                    _quotedAddressCache.value = _quotedAddressCache.value + (raw to note)
                }
            }
        } catch (_: Exception) {}
    }
