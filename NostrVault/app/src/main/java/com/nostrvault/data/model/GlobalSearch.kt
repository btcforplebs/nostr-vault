package com.nostrvault.data.model

import kotlinx.serialization.json.Json
import kotlinx.serialization.json.JsonArray
import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.contentOrNull
import kotlinx.serialization.json.intOrNull
import kotlinx.serialization.json.jsonArray
import kotlinx.serialization.json.jsonObject
import kotlinx.serialization.json.jsonPrimitive
import kotlinx.serialization.json.longOrNull

/**
 * Pure building blocks for Global search: the relay list, query matching,
 * paging, NIP-11, wire parsing, merging and ranking. No Android, no sockets —
 * the session in `service/GlobalSearchSession.kt` wires these to the network,
 * and the unit tests exercise them directly.
 */

// ---------------------------------------------------------------------------
// Search relays
// ---------------------------------------------------------------------------

/**
 * NIP-50 services queried by Global search when the user has not edited the
 * list. From the 2026-09-24 probe of 22 relays: nostr.wine and search.nos.today
 * answer notes and profiles; vertexlab and nostrver.se answer profiles only
 * (and CLOSE a notes REQ, which is why every relay gets separate REQs per kind).
 * relay.nostr.band (handshake timeout) and relay.noswhere.com (0 results for
 * everything) were dropped.
 */
val DEFAULT_SEARCH_RELAYS: List<String> = listOf(
    "wss://nostr.wine",
    "wss://search.nos.today",
    "wss://relay.vertexlab.io",
    "wss://profiles.nostrver.se",
)

object SearchRelayUrls {
    /**
     * Normalises user input into a relay URL: trims, defaults the scheme to
     * `wss://`, drops trailing slashes. Returns null for input that cannot be a
     * relay URL (empty, spaces, http scheme, no host).
     */
    fun normalize(input: String): String? {
        var s = input.trim()
        if (s.isEmpty() || s.any { it.isWhitespace() }) return null
        val lower = s.lowercase()
        if (lower.startsWith("http://") || lower.startsWith("https://")) return null
        if (!lower.startsWith("wss://") && !lower.startsWith("ws://")) {
            if (lower.contains("://")) return null
            s = "wss://$s"
        }
        val scheme = s.substringBefore("://")
        val rest = s.substringAfter("://").trimEnd('/')
        if (rest.isEmpty() || rest.startsWith("/")) return null
        return "$scheme://$rest"
    }

    /** Short label for a status chip: the host without scheme. */
    fun label(url: String): String = url.substringAfter("://").trimEnd('/')
}

// ---------------------------------------------------------------------------
// Query matching
// ---------------------------------------------------------------------------

/**
 * Case-insensitive, all-terms matching for events read out of our own stores
 * (the phone relay and the Mac relay). A store that is paged rather than
 * searched hands back everything, and a Mac relay that claims NIP-50 is still
 * checked, so nothing reaches the results unless every query term is in it.
 *
 * Terms are the query split on whitespace. A query shorter than two characters
 * is refused: one character matches nearly everything.
 */
class SearchTermMatcher private constructor(val terms: List<String>) {

    companion object {
        fun create(query: String): SearchTermMatcher? {
            val trimmed = query.trim()
            if (trimmed.length < 2) return null
            val terms = trimmed.lowercase().split(Regex("\\s+")).filter { it.isNotEmpty() }.distinct()
            if (terms.isEmpty()) return null
            return SearchTermMatcher(terms)
        }
    }

    /** Every term occurs in [text]. */
    fun matches(text: String): Boolean {
        val hay = text.lowercase()
        return terms.all { hay.contains(it) }
    }

    /**
     * A note matches on its own text only — searching a person's name finds
     * them under People, not everything they wrote (Logen, 2026-09-09).
     */
    fun matchesNote(content: String): Boolean = matches(content)

    /** Each term must occur in at least one of the profile's fields. */
    fun matchesProfile(
        displayName: String?,
        name: String?,
        about: String?,
        nip05: String?,
        pubkey: String,
    ): Boolean {
        val fields = listOfNotNull(displayName, name, about, nip05, pubkey).map { it.lowercase() }
        return terms.all { term -> fields.any { it.contains(term) } }
    }

    fun matchesProfile(profile: FeedProfile): Boolean =
        matchesProfile(profile.displayName, profile.name, profile.about, profile.nip05, profile.pubkey)
}

// ---------------------------------------------------------------------------
// Paging our own stores
// ---------------------------------------------------------------------------

/**
 * How a store without NIP-50 is walked. The embedded relay's backends cap a
 * REQ's limit and a filter asking for MORE than the cap is not clamped but
 * dropped to `cap / 4`: LMDB 1500 → 375, Badger 1000 → 250 (phones run
 * Badger). So a page must be <= 1000 and the store is covered by paging with
 * an `until` cursor. Mirrors iOS `LocalRelaySearchPlan`.
 */
object LocalRelaySearchPlan {
    /** Largest limit every backend honours verbatim (Badger's 1000). */
    const val RELAY_MAX_LIMIT = 1000

    /** Events requested per page. Must stay <= [RELAY_MAX_LIMIT]. */
    const val PAGE_LIMIT = RELAY_MAX_LIMIT

    /** 40 pages x 1000 = 40,000 events per route and kind. */
    const val MAX_PAGES = 40

    sealed class Step {
        data object Done : Step()
        data class Next(val until: Long) : Step()
    }

    /**
     * @param received events delivered for this page, before de-duplication.
     * @param newIds how many of those had not arrived on an earlier page.
     * @param oldestCreatedAt smallest `created_at` in this page.
     * @param pagesFetched pages fetched so far, including this one.
     */
    fun step(received: Int, newIds: Int, oldestCreatedAt: Long?, pagesFetched: Int): Step {
        // A short page: the store had nothing more to give.
        if (received < PAGE_LIMIT) return Step.Done
        // `until` is inclusive; a page of pure repeats cannot advance the cursor.
        if (newIds <= 0) return Step.Done
        if (pagesFetched >= MAX_PAGES) return Step.Done
        val oldest = oldestCreatedAt ?: return Step.Done
        return Step.Next(oldest)
    }
}

// ---------------------------------------------------------------------------
// NIP-11
// ---------------------------------------------------------------------------

object Nip11 {
    private val json = Json { ignoreUnknownKeys = true }

    /** http(s) form of a ws(s) relay URL, for the NIP-11 document. */
    fun httpUrl(wsUrl: String): String {
        val t = wsUrl.trim()
        return when {
            t.startsWith("wss://", ignoreCase = true) -> "https://" + t.substring(6)
            t.startsWith("ws://", ignoreCase = true) -> "http://" + t.substring(5)
            else -> t
        }
    }

    /** Whether a NIP-11 document lists 50 in `supported_nips`. */
    fun supportsNip50(body: String): Boolean = try {
        val nips = json.parseToJsonElement(body).jsonObject["supported_nips"] as? JsonArray
        nips?.any { el ->
            val p = el.jsonPrimitive
            p.intOrNull == 50 || p.contentOrNull?.trim() == "50"
        } == true
    } catch (_: Exception) {
        false
    }
}

// ---------------------------------------------------------------------------
// Wire parsing
// ---------------------------------------------------------------------------

/** One relay → client message, reduced to what search needs. */
sealed class SearchWireMessage {
    data class Event(
        val subId: String,
        val id: String,
        val pubkey: String,
        val kind: Int,
        val content: String,
        val createdAt: Long,
        val tags: List<List<String>>,
    ) : SearchWireMessage()

    data class Eose(val subId: String) : SearchWireMessage()
    data class Closed(val subId: String, val reason: String) : SearchWireMessage()
    data object Other : SearchWireMessage()

    companion object {
        private val json = Json { ignoreUnknownKeys = true }

        fun parse(message: String): SearchWireMessage = try {
            val arr = json.parseToJsonElement(message).jsonArray
            val type = arr.getOrNull(0)?.jsonPrimitive?.contentOrNull
            val sid = arr.getOrNull(1)?.jsonPrimitive?.contentOrNull
            when {
                sid == null -> Other
                type == "EOSE" -> Eose(sid)
                type == "CLOSED" -> Closed(sid, arr.getOrNull(2)?.jsonPrimitive?.contentOrNull ?: "")
                type == "EVENT" && arr.size >= 3 -> parseEvent(sid, arr[2].jsonObject) ?: Other
                else -> Other
            }
        } catch (_: Exception) {
            Other
        }

        private fun parseEvent(sid: String, ev: JsonObject): Event? {
            val id = ev["id"]?.jsonPrimitive?.contentOrNull ?: return null
            val pubkey = ev["pubkey"]?.jsonPrimitive?.contentOrNull ?: return null
            val kind = ev["kind"]?.jsonPrimitive?.intOrNull ?: return null
            val content = ev["content"]?.jsonPrimitive?.contentOrNull ?: ""
            val createdAt = ev["created_at"]?.jsonPrimitive?.longOrNull ?: 0L
            val tags = try {
                ev["tags"]?.jsonArray?.map { t -> t.jsonArray.map { it.jsonPrimitive.content } } ?: emptyList()
            } catch (_: Exception) {
                emptyList()
            }
            return Event(sid, id, pubkey, kind, content, createdAt, tags)
        }
    }
}

/** Profile fields out of a kind-0 content string; null if it is not a JSON object. */
fun parseProfileMetadata(pubkey: String, content: String): FeedProfile? = try {
    val m = Json.parseToJsonElement(content).jsonObject
    fun s(key: String) = (m[key] as? kotlinx.serialization.json.JsonPrimitive)?.contentOrNull
    FeedProfile(
        pubkey = pubkey,
        name = s("name"),
        displayName = s("display_name") ?: s("displayName"),
        pictureURL = s("picture"),
        nip05 = s("nip05"),
        about = s("about"),
        lud16 = s("lud16"),
        lud06 = s("lud06"),
        website = s("website"),
    )
} catch (_: Exception) {
    null
}

// ---------------------------------------------------------------------------
// Merge + rank
// ---------------------------------------------------------------------------

/**
 * Results from every source, deduplicated: notes by event id, profiles by
 * pubkey (the newest kind 0 wins, since it is replaceable). Not thread-safe;
 * the session confines it to one lock.
 */
class GlobalSearchAccumulator {
    private val notes = LinkedHashMap<String, FeedNote>()
    private val profiles = LinkedHashMap<String, Pair<FeedProfile, Long>>()

    /** True if [note] was not already held. */
    fun addNote(note: FeedNote): Boolean {
        if (notes.containsKey(note.id)) return false
        notes[note.id] = note
        return true
    }

    /**
     * True if [profile] is new, or replaces an older kind 0 for the same
     * pubkey. Only a *new* pubkey counts toward a source's total — see [isNewProfile].
     */
    fun addProfile(profile: FeedProfile, createdAt: Long): Boolean {
        val existing = profiles[profile.pubkey]
        if (existing != null && existing.second >= createdAt) return false
        profiles[profile.pubkey] = profile to createdAt
        return true
    }

    fun hasProfile(pubkey: String): Boolean = profiles.containsKey(pubkey)
    fun hasNote(id: String): Boolean = notes.containsKey(id)

    fun ranked(own: Set<String>, follows: Set<String>): GlobalSearchResults = GlobalSearchResults(
        profiles = SearchRanking.rankProfiles(profiles.values.map { it.first }, own, follows),
        notes = SearchRanking.rankNotes(notes.values.toList(), own, follows),
    )
}

/**
 * Own posts first, then follows, then everyone; newest first within a tier.
 * Profiles carry no timestamp worth sorting on, so within a tier they keep
 * arrival order (the sort is stable).
 */
object SearchRanking {
    fun tier(pubkey: String, own: Set<String>, follows: Set<String>): Int = when (pubkey) {
        in own -> 0
        in follows -> 1
        else -> 2
    }

    fun rankNotes(notes: List<FeedNote>, own: Set<String>, follows: Set<String>): List<FeedNote> =
        notes.sortedWith(
            compareBy<FeedNote> { tier(it.pubkey, own, follows) }
                .thenByDescending { it.createdAt.time },
        )

    fun rankProfiles(profiles: List<FeedProfile>, own: Set<String>, follows: Set<String>): List<FeedProfile> =
        profiles.sortedBy { tier(it.pubkey, own, follows) }
}

// ---------------------------------------------------------------------------
// Per-source status
// ---------------------------------------------------------------------------

enum class SearchSourceKind { PHONE, MAC, RELAY }

sealed class SearchSourceStatus {
    data object Searching : SearchSourceStatus()
    data class Found(val count: Int) : SearchSourceStatus()
    data class NoAnswer(val reason: String) : SearchSourceStatus()
}

data class SearchSourceState(
    val id: String,
    val label: String,
    val kind: SearchSourceKind,
    val status: SearchSourceStatus = SearchSourceStatus.Searching,
    /** Results this source contributed so far (after dedupe against earlier arrivals). */
    val count: Int = 0,
    /** How it was queried, e.g. "NIP-50" or "scan" for the Mac relay. */
    val detail: String? = null,
)

data class GlobalSearchState(
    val results: GlobalSearchResults = GlobalSearchResults(),
    val sources: List<SearchSourceState> = emptyList(),
    val isRunning: Boolean = false,
)

/**
 * How a source's socket work ended, turned into the status the chip shows.
 * [answered] = at least one subscription EOSEd; [closedReason] = the last
 * CLOSED reason seen; [error] = the connection failed.
 */
fun finalSourceStatus(
    count: Int,
    answered: Boolean,
    timedOut: Boolean,
    closedReason: String?,
    error: String?,
): SearchSourceStatus = when {
    count > 0 -> SearchSourceStatus.Found(count)
    answered -> SearchSourceStatus.Found(0)
    error != null -> SearchSourceStatus.NoAnswer(error)
    closedReason != null -> SearchSourceStatus.NoAnswer(closedReason.ifBlank { "closed" })
    timedOut -> SearchSourceStatus.NoAnswer("timed out")
    else -> SearchSourceStatus.NoAnswer("no reply")
}
