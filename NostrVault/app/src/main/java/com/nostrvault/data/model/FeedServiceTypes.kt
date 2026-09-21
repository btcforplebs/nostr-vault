package com.nostrvault.data.model

import androidx.compose.runtime.Immutable
import androidx.compose.runtime.Stable
import com.nostrvault.relay.HavenQuoteDecoder
import kotlinx.serialization.KSerializer
import kotlinx.serialization.SerialName
import kotlinx.serialization.Serializable
import kotlinx.serialization.descriptors.PrimitiveKind
import kotlinx.serialization.descriptors.PrimitiveSerialDescriptor
import kotlinx.serialization.descriptors.SerialDescriptor
import kotlinx.serialization.encoding.Decoder
import kotlinx.serialization.encoding.Encoder
import kotlinx.serialization.json.Json
import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.contentOrNull
import kotlinx.serialization.json.int
import kotlinx.serialization.json.intOrNull
import kotlinx.serialization.json.jsonPrimitive
import kotlinx.serialization.json.long
import java.net.URL
import java.util.Date

/** Serializer for java.util.Date as epoch milliseconds. */
object DateAsLongSerializer : KSerializer<Date> {
    override val descriptor: SerialDescriptor = PrimitiveSerialDescriptor("Date", PrimitiveKind.LONG)
    override fun serialize(encoder: Encoder, value: Date) = encoder.encodeLong(value.time)
    override fun deserialize(decoder: Decoder): Date = Date(decoder.decodeLong())
}

/**
 * Port of FeedServiceTypes.swift -- core data models for the feed system.
 */

// ---------------------------------------------------------------------------
// Per-note engagement counts
// ---------------------------------------------------------------------------

@Stable
@Serializable
data class NoteStats(
    var reactionCount: Int = 0,
    var repostCount: Int = 0,
    var zapCount: Int = 0,
    var zapAmountSats: Long = 0L,
) {
    /** Aliases for backward compatibility with UI code. */
    val reactions: Int get() = reactionCount
    val reposts: Int get() = repostCount
    val zaps: Int get() = zapCount
}

// ---------------------------------------------------------------------------
// Per-note engagement details (who reacted / zapped / reposted)
// ---------------------------------------------------------------------------

data class ReactionDetail(
    val id: String,
    val pubkey: String,
    val emoji: String,
)

data class ZapDetail(
    val id: String,
    val zapperPubkey: String,
    val amountSats: Long,
    val comment: String,
)

data class RepostDetail(
    val id: String,
    val pubkey: String,
)

data class EngagementDetails(
    val reactions: List<ReactionDetail> = emptyList(),
    val zaps: List<ZapDetail> = emptyList(),
    val reposts: List<RepostDetail> = emptyList(),
)

// ---------------------------------------------------------------------------
// Popular notes DVM result
// ---------------------------------------------------------------------------

@Serializable
data class PopularNoteResult(
    val id: String,
    val pubkey: String,
    val content: String,
    @SerialName("created_at") val createdAt: Long,
    val tags: List<List<String>>,
    val kind: Int,
    val score: Double,
)

// ---------------------------------------------------------------------------
// FeedNote
// ---------------------------------------------------------------------------

@Immutable
@Serializable
data class FeedNote(
    val id: String,
    val pubkey: String,
    val content: String,
    @Serializable(with = DateAsLongSerializer::class)
    val createdAt: Date,
    val tags: List<List<String>>,
    val kind: Int,
    val repostedBy: String? = null,

    // Cached at construction (mirrors iOS init caching)
    val isReply: Boolean,
    val replyToPubkey: String?,
    val parentEventId: String?,
    val mediaURLs: List<String>,
    val linkURLs: List<String>,
    val quotedEventIds: List<String>,
    val repostedEventId: String?,
) {
    /** Instance-level noise check delegating to companion. */
    fun isNoiseOrSpam(): Boolean = Companion.isNoiseOrSpam(content, tags)

    /**
     * NIP-10 thread root id: an explicit "root"-marked e-tag, else the first
     * e-tag, else this note's own id (a top-level note is its own root). This
     * is the symmetric reader for the root tag ComposeNoteScreen writes, and
     * mirrors iOS NoteDetailView.threadRootId. Used to fetch the whole thread
     * subtree when a mid-thread reply is opened.
     */
    val threadRootId: String
        get() {
            val eTags = tags.filter { it.size >= 2 && it[0] == "e" }
            eTags.firstOrNull { it.size >= 4 && it[3] == "root" }?.let { return it[1] }
            return eTags.firstOrNull()?.get(1) ?: effectiveEventId
        }

    /**
     * The event id engagement and replies actually target: for a kind-6
     * repost this is the reposted (inner) event, never the wrapper —
     * replies/zaps/reactions tag the original note, not the repost.
     * Mirrors iOS NoteDetailView's kind-6 redirect.
     */
    val effectiveEventId: String
        get() = if (kind == 6) repostedEventId ?: id else id

    override fun equals(other: Any?): Boolean = other is FeedNote && id == other.id
    override fun hashCode(): Int = id.hashCode()

    companion object {
        /**
         * Every event id these notes can ask the referenced-note cache for:
         * thread parents, thread roots, kind-6 originals and quoted notes.
         *
         * The cache is trimmed against this. Trimming on parent edges alone
         * evicted the *root* of any thread deeper than a direct reply — no
         * row's parent points at it — so a thread card that had just fetched
         * its root lost it again and fell back to "Loading the start of this
         * thread...". Mirrors iOS `ReferencedNoteRepair.referencedIds(in:)`.
         */
        fun referencedIds(notes: List<FeedNote>): Set<String> = buildSet {
            for (note in notes) {
                note.parentEventId?.let { add(it) }
                note.repostedEventId?.let { add(it) }
                add(note.threadRootId)
                addAll(note.quotedEventIds)
            }
        }

        // Regex patterns (compiled once)
        private val MEDIA_REGEX = Regex(
            """https?://[^\s<>")\]]*\.(?:jpg|jpeg|png|gif|webp|svg|bmp|tiff|avif|mp4|mov|webm|avi|mkv|m4v|mp3|m4a|wav|ogg|aac|flac|opus)(?:[?#][^\s<>")\]]*[^\s<>")\].,;:!?'"])?""",
            RegexOption.IGNORE_CASE,
        )
        private val BLOSSOM_REGEX = Regex(
            """https?://\S+/[a-f0-9]{64}(?=\s|$)""",
            RegexOption.IGNORE_CASE,
        )
        private val HTTP_URL_REGEX = Regex(
            """https?://[^\s<>")\]]*[^\s<>")\].,;:!?'"]""",
            RegexOption.IGNORE_CASE,
        )

        /**
         * Construct a FeedNote with NIP-18 repost resolution and cached properties.
         */
        operator fun invoke(
            id: String,
            pubkey: String,
            content: String,
            createdAt: Date,
            tags: List<List<String>>,
            kind: Int,
            repostedBy: String? = null,
        ): FeedNote {
            // NIP-18: kind 6 repost -- extract reposted event ID from outer e-tags
            val outerETags = tags.filter { it.size >= 2 && it[0] == "e" }
            val outerRepostedEventId = if (kind == 6) outerETags.firstOrNull()?.get(1) else null

            var resolvedPubkey = pubkey
            var resolvedContent = content
            var resolvedTags = tags
            var resolvedRepostedBy = repostedBy

            // Kind 6: swap to inner event if content is stringified JSON
            if (kind == 6) {
                try {
                    val inner = Json.decodeFromString<JsonObject>(content)
                    val innerContent = inner["content"]?.jsonPrimitive?.contentOrNull
                    val innerPubkey = inner["pubkey"]?.jsonPrimitive?.contentOrNull
                    if (innerContent != null && innerPubkey != null) {
                        resolvedPubkey = innerPubkey
                        resolvedContent = innerContent
                        // Parse inner tags if present
                        val innerTags = inner["tags"]
                        if (innerTags != null) {
                            resolvedTags = Json.decodeFromString(innerTags.toString())
                        }
                        if (resolvedRepostedBy == null) resolvedRepostedBy = pubkey
                    }
                } catch (_: Exception) {
                    // Content is not JSON, keep outer values
                }
            }

            // Cache tag-derived properties
            val eTags = resolvedTags.filter { it.size >= 2 && it[0] == "e" }
            val nonMentionETags = eTags.filter { tag ->
                tag.size < 4 || tag[3] != "mention"
            }
            val isReply = kind != 6 && nonMentionETags.isNotEmpty()
            val replyToPubkey = if (kind != 6) {
                resolvedTags.firstOrNull { it.size >= 2 && it[0] == "p" }?.get(1)
            } else null
            val parentEventId = if (kind != 6) {
                resolvedTags.lastOrNull { it.size >= 2 && it[0] == "e" }?.get(1)
            } else null

            // Parse media URLs from content + imeta tags
            val contentMediaUrls = parseMediaURLs(resolvedContent)
            val imetaUrls = resolvedTags.mapNotNull { tag ->
                if (tag.firstOrNull() != "imeta" || tag.size < 2) return@mapNotNull null
                tag.drop(1).firstOrNull { it.startsWith("url ") }
                    ?.removePrefix("url ")?.trim()
            }
            val seen = mutableSetOf<String>()
            val mediaURLs = (contentMediaUrls + imetaUrls).filter { seen.add(it) }

            val linkURLs = parseLinkURLs(resolvedContent, mediaURLs.toSet())
            val quotedEventIds = parseQuotedEventIds(resolvedContent)

            return FeedNote(
                id = id,
                pubkey = resolvedPubkey,
                content = resolvedContent,
                createdAt = createdAt,
                tags = resolvedTags,
                kind = kind,
                repostedBy = resolvedRepostedBy,
                isReply = isReply,
                replyToPubkey = replyToPubkey,
                parentEventId = parentEventId,
                mediaURLs = mediaURLs,
                linkURLs = linkURLs,
                quotedEventIds = quotedEventIds,
                repostedEventId = outerRepostedEventId,
            )
        }

        private fun parseMediaURLs(content: String): List<String> {
            val urls = mutableListOf<String>()
            urls += MEDIA_REGEX.findAll(content).map { it.value }
            urls += BLOSSOM_REGEX.findAll(content).map { it.value }
            return urls
        }

        private fun parseLinkURLs(content: String, mediaSet: Set<String>): List<String> {
            val seen = mutableSetOf<String>()
            return HTTP_URL_REGEX.findAll(content)
                .map { it.value }
                .filter { it !in mediaSet }
                .filter { seen.add(it) }
                .toList()
        }

        /**
         * The lookup keys for the events this note quotes: a hex event id for
         * `note1`/`nevent1`, and an `naddr:<kind>:<pubkey>:<d>` coordinate for
         * `naddr1`.
         *
         * Callers fetch by these, so what comes out has to be what the fetcher
         * accepts — which is why the decode lives in [QuoteRef] and not here.
         * This used to pass the bech32 string straight through; then it was
         * changed to hand out hex while FeedService still expected bech32, so
         * every lookup was rejected and no quote rendered either way. One
         * definition, used by both ends, is the fix for both bugs.
         *
         * naddr points at a replaceable event — a long-form article, a live
         * stream — addressed by kind/author/identifier rather than by id.
         * Dropping it used to mean a quoted article vanished with no card, no
         * placeholder and no text, because the reference is stripped out of the
         * body as well.
         */
        private fun parseQuotedEventIds(content: String): List<String> =
            QuoteRef.resolvedIdentifiers(content, HavenQuoteDecoder)

        /**
         * Factory from raw event fields (Long timestamp → Date).
         */
        fun fromEvent(
            id: String,
            pubkey: String,
            content: String,
            tags: List<List<String>>,
            createdAt: Long,
            kind: Int,
            repostedBy: String? = null,
        ): FeedNote = FeedNote(
            id = id,
            pubkey = pubkey,
            content = content,
            createdAt = Date(createdAt * 1000),
            tags = tags,
            kind = kind,
            repostedBy = repostedBy,
        )

        /**
         * Technical heuristic to filter out spam, bots, empty, duplicate, or telemetry noise.
         */
        fun isNoiseOrSpam(content: String, tags: List<List<String>>): Boolean {
            val trimmed = content.trim()
            if (trimmed.isEmpty()) return true

            // JSON / technical payloads
            if (trimmed.startsWith("{") && trimmed.endsWith("}")) return true

            val lower = trimmed.lowercase()
            if ("nostr-wallet-connect" in lower ||
                "\"method\":" in lower ||
                "\"result\":" in lower ||
                "nip47" in lower
            ) return true

            // Excessive consecutive repeated characters
            var consecutiveCount = 1
            var lastChar: Char? = null
            for (char in trimmed) {
                if (char == lastChar) {
                    consecutiveCount++
                    if (consecutiveCount >= 20) return true
                } else {
                    consecutiveCount = 1
                }
                lastChar = char
            }

            // Hashtag / mention stuffing. Skip the mention half for replies: NIP-10
            // has them correctly carry a p-tag for every thread participant (so
            // everyone gets notified), which easily exceeds this threshold in a
            // busy thread — that's normal protocol structure, not spam, and hiding
            // it made people's own replies vanish from thread views.
            if (trimmed.length < 100) {
                val hashtags = tags.count { it.size >= 2 && it[0] == "t" }
                val isReply = tags.any { it.size >= 2 && it[0] == "e" && (it.size < 4 || it[3] != "mention") }
                val mentions = tags.count { it.size >= 2 && it[0] == "p" }
                if (hashtags > 6 || (!isReply && mentions > 6)) return true
            }

            // Common spam keywords
            val spamKeywords = listOf(
                "relay status:", "relay uptime:", "ping time:", "block height:",
                "free bitcoin", "earn double bitcoin", "telegram channel for free",
                "pump telegram", "whatsapp group", "click here to claim",
            )
            if (spamKeywords.any { it in lower }) return true

            return false
        }
    }
}

// ---------------------------------------------------------------------------
// FeedProfile
// ---------------------------------------------------------------------------

@Stable
@Serializable
data class FeedProfile(
    val pubkey: String,
    var name: String? = null,
    var displayName: String? = null,
    var pictureURL: String? = null,
    var nip05: String? = null,
    var about: String? = null,
    var lud16: String? = null,
    var lud06: String? = null,
    var website: String? = null,
    /** Epoch millis of the last successful metadata fetch; null for legacy/unstamped entries. */
    var fetchedAt: Long? = null,
) {
    /** Best display name: display_name > name > truncated pubkey. Computed once at
     *  construction (profiles are replaced via copy(), never mutated in place), so
     *  hot-path reads (~30/frame across feed rows) don't re-run the fallback chain.
     *  A body property is not serialized, so this stays out of profiles.json. */
    val bestName: String = displayName?.takeIf { it.isNotBlank() }
        ?: name?.takeIf { it.isNotBlank() }
        ?: "${pubkey.take(8)}..."
}

// ---------------------------------------------------------------------------
// Feed mode enums
// ---------------------------------------------------------------------------

enum class FeedMode(val displayName: String) {
    FOLLOWING("Following"),
    DISCOVERY("Discovery"),
    GLOBAL("Global"),
    POPULAR("Popular"),
    MEDIA("Media"),

    /**
     * Long-form articles (kind 30023). The events were already arriving — the
     * feed subscription has asked for kind 30023 all along and the dashboard
     * counts them — so this mode is a lens on what the relay already holds,
     * not a new fetch.
     */
    ARTICLES("Articles"),

    /**
     * Recipes: the same kind-30023 long-form events, tagged for zap.cooking.
     * A separate mode rather than a filter chip because a recipe list is what
     * you want when you want a recipe, and articles and recipes read nothing
     * alike even though the wire format is identical.
     */
    RECIPES("Recipes"),

    /**
     * NIP-53 live streams (kind 30311). Unlike every other mode this is not a
     * view of the note list — live events are replaceable announcements
     * fetched fresh each time, because one that ended two minutes ago still
     * says "live" in anything cached.
     */
    LIVE("Live"),
}

/** `t` topics zap.cooking publishes recipes under; category tags are `zapcooking-<category>`. */
object RecipeTopics {
    const val CATEGORY_PREFIX = "zapcooking-"
    val BASE = listOf("zapcooking", "nostrcooking")

    /** True when this note carries one of the recipe topics. */
    fun matches(tags: List<List<String>>): Boolean = tags.any { tag ->
        tag.size >= 2 && tag[0] == "t" && tag[1].lowercase().let { topic ->
            topic in BASE || topic.startsWith(CATEGORY_PREFIX)
        }
    }
}

enum class MediaFeedMode(val displayName: String) {
    FOLLOWING("Following"),
    GLOBAL("Global"),
}

enum class PopularFilter(val displayName: String) {
    ALL("All"),
    FOLLOWS("Follows"),
    NON_FOLLOWS("Non-Follows"),
}

// ---------------------------------------------------------------------------
// Account snapshots (for instant account switching)
// ---------------------------------------------------------------------------

data class AccountFeedSnapshot(
    var notes: List<FeedNote> = emptyList(),
    var parentNotesCache: Map<String, FeedNote> = emptyMap(),
    var followedPubkeys: List<String> = emptyList(),
    var extendedNetworkPubkeys: List<String> = emptyList(),
    var seenIds: MutableSet<String> = mutableSetOf(),
    var noteStats: Map<String, NoteStats> = emptyMap(),
    var likedEventIds: MutableSet<String> = mutableSetOf(),
    var zappedEventIds: MutableMap<String, Int> = mutableMapOf(),
    var contactListContent: String = "",
    var contactListPTags: List<List<String>> = emptyList(),
    var lastFetchedContactCount: Int = 0,
    var hasAttemptedContactLoad: Boolean = false,
    var capturedAt: Date = Date(),
    var lastEventTimestamp: Long = 0L,
)

// ---------------------------------------------------------------------------
// Background accumulator (thread-safe event buffer)
// ---------------------------------------------------------------------------

class BackgroundAccumulator {
    private val lock = Any()

    val notes = mutableListOf<FeedNote>()
    val profiles = mutableListOf<String>()
    val reactionEvents = mutableListOf<Pair<String, String>>() // (targetId, pubkey)
    val zapEvents = mutableListOf<Pair<String, Long>>() // (targetId, amountSats)
    val repostTargets = mutableListOf<String>()
    val rawEventEntries = mutableListOf<Pair<String, String>>() // (id, json)
    var flushScheduled = false

    val seenEngagementIds = mutableSetOf<String>()

    var isInitialLoad = false
    var isGlobalMode = false

    val effectiveFlushIntervalMs: Long
        get() = when {
            isGlobalMode -> 50L
            isInitialLoad -> 200L
            else -> 500L
        }

    /** Add a content note to the buffer. */
    fun addNote(note: FeedNote) { synchronized(lock) { notes.add(note) } }

    /** Add a reaction engagement event. */
    fun addReaction(targetId: String, pubkey: String) { synchronized(lock) { reactionEvents.add(targetId to pubkey) } }

    /** Add a zap engagement event. */
    fun addZap(targetId: String, amountSats: Long) { synchronized(lock) { zapEvents.add(targetId to amountSats) } }

    data class Snapshot(
        val notes: List<FeedNote>,
        val profiles: List<String>,
        val reactions: List<Pair<String, String>>,
        val zaps: List<Pair<String, Long>>,
        val repostTargets: List<String>,
        val rawEventEntries: List<Pair<String, String>>,
    )

    fun drain(): Snapshot {
        synchronized(lock) {
            val snap = Snapshot(
                notes = notes.toList(),
                profiles = profiles.toList(),
                reactions = reactionEvents.toList(),
                zaps = zapEvents.toList(),
                repostTargets = repostTargets.toList(),
                rawEventEntries = rawEventEntries.toList(),
            )
            notes.clear()
            profiles.clear()
            reactionEvents.clear()
            zapEvents.clear()
            repostTargets.clear()
            rawEventEntries.clear()
            flushScheduled = false

            // Cap dedup set
            if (seenEngagementIds.size > MAX_ENGAGEMENT_IDS) {
                val keep = seenEngagementIds.sortedDescending().take(MAX_ENGAGEMENT_IDS / 2)
                seenEngagementIds.clear()
                seenEngagementIds.addAll(keep)
            }
            return snap
        }
    }

    companion object {
        private const val MAX_ENGAGEMENT_IDS = 20_000
    }
}
