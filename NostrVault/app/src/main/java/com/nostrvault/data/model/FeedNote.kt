package com.nostrvault.data.model

import com.nostrvault.util.findAllOnce
import androidx.compose.runtime.Immutable
import com.nostrvault.relay.HavenQuoteDecoder
import kotlinx.serialization.Serializable
import kotlinx.serialization.json.Json
import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.contentOrNull
import kotlinx.serialization.json.intOrNull
import kotlinx.serialization.json.jsonPrimitive
import kotlinx.serialization.json.long
import kotlinx.serialization.json.longOrNull
import java.net.URL
import java.util.Date

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
    /**
     * When the reposted note was written (unix seconds), from a kind 6
     * repost's embedded event. [createdAt] stays the repost's own time, which
     * orders the feed (iOS e4ae7da3).
     */
    val originalCreatedAtSecs: Long? = null,
    /**
     * The reposted note's own kind (an article is 30023, a poll 1068), from a
     * kind 6 repost's embedded event or the original a bare one resolved to.
     * [kind] stays 6 so engagement still targets the original.
     */
    val originalKind: Int? = null,
) {
    /** The kind this row is drawn as: a repost shows its original's kind. */
    val displayKind: Int
        get() = originalKind ?: kind

    /** When the note this row shows was written: a repost's original time. */
    val postedAt: Date
        get() = originalCreatedAtSecs?.let { Date(it * 1000) } ?: createdAt

    /** Instance-level noise check delegating to companion. */
    fun isNoiseOrSpam(): Boolean = Companion.isNoiseOrSpam(content, tags)

    /**
     * [isNoiseOrSpam], computed once per note. The feed filter re-checks every
     * note (up to MAX_FEED_NOTES) twice per relay batch, and each check copies
     * and lowercases the whole content — garbage the GC then collected while
     * the user scrolled. A delegated property has no backing field, so it is
     * not serialized into the snapshot.
     *
     * A bare repost is never noise: the empty-content rule threw it away, but
     * it is valid NIP-18 and its row fetches the note it points at. 2 of the 9
     * notes missing from two hours of a Following feed on 2026-10-04 were
     * these (iOS #227). Nor is a picture post (NIP-68): its pictures are in
     * `imeta` tags and its caption may well be empty.
     */
    val isNoise: Boolean by lazy(LazyThreadSafetyMode.PUBLICATION) {
        !isBareRepost && !(displayKind == PICTURE_KIND && mediaURLs.isNotEmpty()) &&
            Companion.isNoiseOrSpam(content, tags)
    }

    /** A kind 6 repost that only points at the original: empty content plus an `e` tag. */
    val isBareRepost: Boolean
        get() = kind == 6 && content.isEmpty() && repostedEventId != null

    /**
     * This bare repost drawn the way an embedded one is: [original]'s author,
     * text, tags and media, credited to the reposter, keeping this repost's id
     * and time so it stays put in the feed.
     */
    fun withRepostedOriginal(original: FeedNote): FeedNote = copy(
        pubkey = original.pubkey,
        content = original.content,
        tags = original.tags,
        repostedBy = pubkey,
        mediaURLs = original.mediaURLs,
        linkURLs = original.linkURLs,
        quotedEventIds = original.quotedEventIds,
        originalCreatedAtSecs = original.createdAt.time / 1000,
        originalKind = original.displayKind,
    )

    /**
     * Thread root id, read by [NIP10Thread.rootEventId]: a NIP-22 comment's
     * uppercase `E`; for NIP-10 an explicit "root"-marked e-tag, else the
     * first non-mention e-tag; else this note's own id (a top-level note is
     * its own root). This is the symmetric reader for the root tag
     * ComposeNoteScreen writes, and mirrors iOS NoteDetailView.threadRootId.
     * Used to fetch the whole thread subtree when a mid-thread reply is opened.
     */
    val threadRootId: String
        get() = if (displayKind == FeedHighlight.KIND) {
            // Its `e` tag names the passage's source, not a thread root.
            effectiveEventId
        } else {
            NIP10Thread.rootEventId(kind, tags) ?: effectiveEventId
        }

    /**
     * The event id engagement and replies actually target: for a kind-6
     * repost this is the reposted (inner) event, never the wrapper —
     * replies/zaps/reactions tag the original note, not the repost.
     * Mirrors iOS NoteDetailView's kind-6 redirect.
     */
    val effectiveEventId: String
        get() = if (kind == 6) repostedEventId ?: id else id

    /**
     * Who wrote the note engagement targets. Zaps, reports and blocks go
     * here, never to the reposter. A repost that still holds its own
     * `["e", repostedEventId]` tag was not unpacked and carries the
     * reposter's pubkey, so the author comes from its `p` tag (the same test
     * as [quoteTarget]). An embedded or resolved repost already holds the
     * original's author.
     */
    val effectiveAuthor: String
        get() {
            val refId = repostedEventId
            if (kind != 6 || refId == null) return pubkey
            val stillWrapped = tags.any { it.size >= 2 && it[0] == "e" && it[1] == refId }
            if (!stillWrapped) return pubkey
            return tags.firstOrNull { it.size >= 2 && it[0] == "p" }?.get(1) ?: pubkey
        }

    /** The kind of the note engagement targets: a kind-6 repost's original, a kind 1 when unknown. */
    val effectiveKind: Int
        get() = if (kind == 6 && repostedEventId != null) originalKind ?: 1 else kind

    /** Who published this event: the reposter for a repost, else the author. */
    val publisher: String
        get() = if (kind == 6) repostedBy ?: pubkey else pubkey

    /**
     * The links that get a card, and so leave the text. Capped: each card
     * fetches its page, and a note can carry thousands of URLs to a host the
     * poster controls (Tron, #183). Links past the cap stay in the text.
     */
    val cardLinkURLs: List<String>
        get() = linkURLs.take(MAX_LINK_CARDS)

    /** The note's NIP-30 emoji by shortcode, for drawing `:shortcode:` in its text. */
    val customEmojis: Map<String, com.nostrvault.service.CustomEmoji> by lazy(LazyThreadSafetyMode.PUBLICATION) {
        com.nostrvault.service.CustomEmoji.fromTags(tags)
    }

    override fun equals(other: Any?): Boolean = other is FeedNote && id == other.id
    override fun hashCode(): Int = id.hashCode()

    companion object {
        const val MAX_LINK_CARDS = 3

        /** NIP-68 picture post. */
        const val PICTURE_KIND = 20

        /**
         * Every kind the timelines (Following, Discovery, Global, Popular) ask
         * for and draw as a card. The relay's feed cache holds the same set
         * (`haven-go/feedsync.go` `feedKinds`). iOS `FeedNote.timelineKinds`.
         */
        val TIMELINE_KINDS: List<Int> = listOf(
            1, 6, ArticleMeta.KIND, NIP10Thread.COMMENT_KIND, NIP88Poll.KIND,
            GenericRepost.KIND, PICTURE_KIND, FeedHighlight.KIND,
        )

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

        /**
         * The note a quote of [note] should cite. Quoting a kind-6 repost has
         * to cite the note it carries, by id *and* author: the composer gets
         * the original's id ([effectiveEventId]) but used to read the author
         * off the repost, so a bare repost's `q`/`p` tags and preview named
         * the reposter.
         *
         * Uses the loaded original when [loadedOriginal] has it. Otherwise
         * rebuilds it from the repost, trusting the author/body/tags only if
         * the constructor really unpacked the NIP-18 embedded event. That is
         * read from the tags, not the content: a repost's own tags always hold
         * `["e", repostedEventId]` and no event can tag its own id, so a note
         * still holding that tag was not unpacked and carries the reposter's
         * identity — the author then comes from the repost's `p` tag.
         * Mirrors iOS `FeedService.quoteTarget(for:)` (#66, #67).
         */
        fun quoteTarget(note: FeedNote, loadedOriginal: (String) -> FeedNote?): FeedNote {
            if (note.kind != 6) return note
            val refId = note.repostedEventId ?: return note
            loadedOriginal(refId)?.takeIf { it.id == refId && it.kind != 6 }?.let { return it }
            val stillWrapped = note.tags.any { it.size >= 2 && it[0] == "e" && it[1] == refId }
            if (!stillWrapped) {
                return FeedNote(
                    id = refId,
                    pubkey = note.pubkey,
                    content = note.content,
                    createdAt = note.createdAt,
                    tags = note.tags,
                    kind = 1,
                )
            }
            val author = note.tags.firstOrNull { it.size >= 2 && it[0] == "p" }?.get(1) ?: note.pubkey
            return FeedNote(
                id = refId,
                pubkey = author,
                content = "",
                createdAt = note.createdAt,
                tags = emptyList(),
                kind = 1,
            )
        }

        // Regex patterns (compiled once)
        private val MEDIA_REGEX = Regex(
            // The extension has to end the URL's text, or https://www.avid.com
            // matched as https://www.avi. Same rule as iOS SupportedMediaFormats.
            """https?://[^\s<>")\]]*?\.(?:jpg|jpeg|png|gif|webp|svg|bmp|tiff|avif|mp4|mov|webm|avi|mkv|m4v|mp3|m4a|wav|ogg|aac|flac|opus)(?=$|[^\w/.\-]|[.\-](?!\w))(?:[?#][^\s<>")\]]*[^\s<>")\].,;:!?'"])?""",
            RegexOption.IGNORE_CASE,
        )
        private val BLOSSOM_REGEX = Regex(
            """https?://\S+/[a-f0-9]{64}(?=\s|$)""",
            RegexOption.IGNORE_CASE,
        )
        private val MEDIA_EXTENSIONS = setOf(
            "jpg", "jpeg", "png", "gif", "webp", "svg", "bmp", "tiff", "avif",
            "mp4", "mov", "webm", "avi", "mkv", "m4v",
            "mp3", "m4a", "wav", "ogg", "aac", "flac", "opus",
        )
        private val HEX_64 = Regex("^[a-fA-F0-9]{64}$")

        /**
         * Nostr web clients and gateways. They serve a web page, not a file, at
         * `/<64-hex>` (an event id or pubkey), so their hex links aren't Blossom
         * blobs. Exact hosts: blossom.primal.net is a real Blossom server.
         * Same list as iOS SupportedMediaFormats.webPageHosts.
         */
        val WEB_PAGE_HOSTS = setOf(
            "njump.me", "njump.to", "primal.net", "nostr.band", "snort.social",
            "iris.to", "coracle.social", "nostrudel.ninja", "habla.news",
            "yakihonne.com", "nostter.app", "jumble.social", "nostr.com",
            "damus.io", "zap.stream", "highlighter.com", "nostr.at", "nostr.eu",
            "nostrrr.com", "flycat.club", "nostrapp.link", "nostr.watch",
        )

        private fun uri(url: String): java.net.URI? =
            try { java.net.URI(url) } catch (_: Exception) { null }

        private fun extensionOf(path: String): String =
            path.substringAfterLast('/').substringAfterLast('.', "").lowercase()

        private fun isWebPageHost(host: String?): Boolean =
            host?.lowercase()?.removePrefix("www.") in WEB_PAGE_HOSTS

        /**
         * Whether [url] names a file the media grid can draw: a media extension
         * on its path (not its host: .mov is also a TLD), or a Blossom SHA-256
         * path on a host that isn't a web page. iOS SupportedMediaFormats.isMediaURL.
         */
        fun isMediaUrl(url: String): Boolean {
            val u = uri(url) ?: return false
            val scheme = u.scheme?.lowercase()
            if (scheme != "http" && scheme != "https") return false
            val path = u.rawPath.orEmpty()
            if (extensionOf(path) in MEDIA_EXTENSIONS) return true
            val last = path.substringAfterLast('/')
            return HEX_64.matches(last) && !isWebPageHost(u.host)
        }

        /** An imeta URL is media unless it is a web page: no media extension on a web-client host. */
        fun isImetaMediaUrl(url: String): Boolean {
            val u = uri(url) ?: return true
            if (extensionOf(u.rawPath.orEmpty()) in MEDIA_EXTENSIONS) return true
            return !isWebPageHost(u.host)
        }

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
            // A generic repost (16) is a repost of anything but a text note.
            // Every repost rule (reposter-follows membership, the reposts
            // toggle, the original fetched and drawn as its own kind) is the
            // same, so it is held as a 6 from here on. iOS FeedNote.init.
            val isGenericRepost = kind == GenericRepost.KIND
            val feedKind = if (isGenericRepost) 6 else kind

            // NIP-18: kind 6 repost -- extract reposted event ID from outer e-tags
            val outerETags = tags.filter { it.size >= 2 && it[0] == "e" }
            val outerRepostedEventId = if (feedKind == 6) outerETags.firstOrNull()?.get(1) else null

            var resolvedPubkey = pubkey
            var resolvedContent = content
            var resolvedTags = tags
            var resolvedRepostedBy = if (isGenericRepost) repostedBy ?: pubkey else repostedBy
            var originalCreatedAtSecs: Long? = null
            var originalKind: Int? = null

            // Kind 6: swap to inner event if content is stringified JSON
            if (feedKind == 6) {
                try {
                    val inner = Json.decodeFromString<JsonObject>(content)
                    val innerContent = inner["content"]?.jsonPrimitive?.contentOrNull
                    val innerPubkey = inner["pubkey"]?.jsonPrimitive?.contentOrNull
                    if (innerContent != null && innerPubkey != null) {
                        resolvedPubkey = innerPubkey
                        resolvedContent = innerContent
                        // The inner event's tags, never the repost's: keeping the
                        // outer `e`/`p` here would make an unpacked repost look
                        // bare to [quoteTarget], which tells them apart by tags.
                        val innerTags = inner["tags"]
                        resolvedTags = if (innerTags != null) {
                            Json.decodeFromString(innerTags.toString())
                        } else {
                            emptyList()
                        }
                        if (resolvedRepostedBy == null) resolvedRepostedBy = pubkey
                        originalCreatedAtSecs = inner["created_at"]?.jsonPrimitive?.longOrNull
                        originalKind = inner["kind"]?.jsonPrimitive?.intOrNull
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
            // A highlight's `e`/`p` name its source, not a thread it replies in.
            val threads = feedKind != 6 && feedKind != FeedHighlight.KIND
            val isReply = threads && nonMentionETags.isNotEmpty()
            // The parent's author, not the first `p` (the thread's starter).
            val replyToPubkey = if (isReply) {
                NIP10Thread.parentAuthor(feedKind, resolvedTags)
            } else null
            val parentEventId = if (threads) {
                NIP10Thread.parentEventId(feedKind, resolvedTags)
            } else null

            // Parse media URLs from content + imeta tags
            val contentMediaUrls = parseMediaURLs(resolvedContent)
            val imetaUrls = resolvedTags.mapNotNull { tag ->
                if (tag.firstOrNull() != "imeta" || tag.size < 2) return@mapNotNull null
                tag.drop(1).firstOrNull { it.startsWith("url ") }
                    ?.removePrefix("url ")?.trim()
                    ?.takeIf(::isImetaMediaUrl)
            }
            val seen = mutableSetOf<String>()
            val mediaURLs = (contentMediaUrls + imetaUrls).filter { seen.add(it) }
            BlossomUri.register(mediaURLs, resolvedPubkey)

            val linkURLs = parseLinkURLs(resolvedContent, mediaURLs.toSet())
            // A highlight's source rides the quote path: fetched, drawn and
            // opened like a quoted note, under the passage.
            val shownKind = if (feedKind == 6) originalKind else feedKind
            val highlightSource = if (shownKind == FeedHighlight.KIND) FeedHighlight.sourceReference(resolvedTags) else null
            val quotedEventIds = parseQuotedEventIds(resolvedContent) + listOfNotNull(highlightSource)

            return FeedNote(
                id = id,
                pubkey = resolvedPubkey,
                content = resolvedContent,
                createdAt = createdAt,
                tags = resolvedTags,
                kind = feedKind,
                repostedBy = resolvedRepostedBy,
                isReply = isReply,
                replyToPubkey = replyToPubkey,
                parentEventId = parentEventId,
                mediaURLs = mediaURLs,
                linkURLs = linkURLs,
                quotedEventIds = quotedEventIds,
                repostedEventId = outerRepostedEventId,
                originalCreatedAtSecs = originalCreatedAtSecs,
                originalKind = originalKind,
            )
        }

        internal fun parseMediaURLs(content: String): List<String> {
            val urls = mutableListOf<String>()
            urls += MEDIA_REGEX.findAllOnce(content).map { it.value }
            urls += BLOSSOM_REGEX.findAllOnce(content).map { it.value }
            // BUD-10 `blossom:` links with a media extension; a `.pdf` stays text.
            val bud10 = BlossomUri.TOKEN.findAllOnce(content).map { it.value }
                .filter { BlossomUri.parse(it)?.ext?.let { ext -> ext in MEDIA_EXTENSIONS } == true }
            return urls.filter(::isMediaUrl) + bud10
        }

        /** Every non-media http(s) URL in [content], in order, each once. */
        internal fun parseLinkURLs(content: String, mediaSet: Set<String>): List<String> {
            val seen = mutableSetOf<String>()
            return HTTP_URL_REGEX.findAllOnce(content)
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
