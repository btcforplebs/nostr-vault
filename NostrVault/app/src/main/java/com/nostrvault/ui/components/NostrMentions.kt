package com.nostrvault.ui.components

import com.nostrvault.data.model.FeedProfile
import com.nostrvault.data.model.QuoteRef
import com.nostrvault.relay.HavenBridge
import java.util.concurrent.ConcurrentHashMap

/**
 * Shared NIP-19 mention resolution used by both the clickable [NostrContentText]
 * renderer and single-line plain-text previews, so they agree on how
 * `nostr:npub1.../nostr:nprofile1...` references resolve to a pubkey / display name.
 */
object NostrMentions {

    /** `nostr:npub1...` / `nostr:nprofile1...` profile mentions. */
    val MENTION_REGEX = Regex(
        """nostr:(npub1[a-z0-9]+|nprofile1[a-z0-9]+)""",
        RegexOption.IGNORE_CASE,
    )

    /**
     * `nostr:note1...` / `nostr:nevent1...` / `nostr:naddr1...` event references.
     * Aliases [QuoteRef.REGEX] rather than restating it, so what the renderer
     * strips out of the text is exactly what the note parser turned into a card.
     */
    val QUOTE_REGEX = QuoteRef.REGEX

    // npub/nprofile → hex is an immutable mapping, so cache decodes for the whole
    // process. The same npub is mentioned across many notes/frames; a full bech32
    // decode (~63 charset scans + allocations) per occurrence was a real hot-path
    // cost. "" is the sentinel for "undecodable" so negatives are cached too.
    private val decodeCache = ConcurrentHashMap<String, String>()

    /** Resolve an npub/nprofile bech32 identifier to a hex pubkey. */
    fun resolvePubkey(identifier: String): String? {
        decodeCache[identifier]?.let { return it.ifEmpty { null } }
        val resolved = decodeBech32(identifier)
        decodeCache[identifier] = resolved ?: ""
        return resolved
    }

    private fun decodeBech32(identifier: String): String? {
        return when {
            identifier.startsWith("npub1", ignoreCase = true) -> HavenBridge.decodeNpub(identifier)
            identifier.startsWith("nprofile1", ignoreCase = true) -> {
                // decodeNprofile returns JSON: {"pubkey":"...","relays":[...]}
                val json = HavenBridge.decodeNprofile(identifier) ?: return null
                val keyStart = json.indexOf("\"pubkey\":\"")
                if (keyStart < 0) return null
                val start = keyStart + 10
                val end = json.indexOf("\"", start)
                if (end < 0) null else json.substring(start, end)
            }
            else -> null
        }
    }

    /**
     * Every pubkey [content] mentions, hex, in appearance order.
     *
     * Lets a caller resolve exactly the profiles one note can display instead
     * of reading the whole profile map, which is what makes a feed row's
     * profile lookups narrowable to that row.
     */
    fun mentionedPubkeys(content: String): List<String> =
        MENTION_REGEX.findAll(content)
            .mapNotNull { resolvePubkey(it.groupValues[1]) }
            .distinct()
            .toList()

    /** Display label for a mention: the profile's best name, else a short pubkey. */
    private fun displayName(pubkey: String, profiles: Map<String, FeedProfile>): String =
        profiles[pubkey]?.bestName ?: "${pubkey.take(8)}…"

    /**
     * Resolve nostr mentions in [content] to plain `@name` text and strip
     * `nostr:note/nevent/naddr` quote references (rendered separately as cards).
     * Used for single-line preview rows where a clickable renderer is overkill.
     *
     * Pass [mediaURLs] when the caller draws that media itself. The URL is then
     * dropped from the text, because a raw
     * `https://…/40051f70….mp4` sitting above its own thumbnail is noise — the
     * full renderer already strips them, and this one used to not, so the same
     * note read differently depending on which card drew it.
     */
    fun toPlainText(
        content: String,
        profiles: Map<String, FeedProfile>,
        mediaURLs: Set<String> = emptySet(),
        linkURLs: Set<String> = emptySet(),
    ): String {
        var text = MENTION_REGEX.replace(content) { match ->
            val identifier = match.groupValues[1]
            val pubkey = resolvePubkey(identifier)
            if (pubkey != null) "@${displayName(pubkey, profiles)}" else "@${identifier.take(10)}…"
        }
        text = QUOTE_REGEX.replace(text, "")
        return stripUrls(text, mediaURLs + linkURLs)
    }

    private val SPACE_RUN = Regex("""[ \t]{2,}""")

    /**
     * Remove [urls] from [text], longest first so `a.com` cannot cut into
     * `a.com/page`, then close the gap each one left: a URL taken from
     * mid-sentence leaves one space, and a note that was only a URL becomes
     * empty. Newlines are kept. Same rule as iOS `stripURLs` (#170).
     */
    fun stripUrls(text: String, urls: Collection<String>): String {
        var out = text
        for (url in urls.filter { it.isNotEmpty() }.sortedByDescending { it.length }) {
            out = out.replace(url, "")
        }
        return collapseGaps(out).trim()
    }

    /** Runs of spaces or tabs become one space; newlines are left alone. */
    fun collapseGaps(text: String): String = SPACE_RUN.replace(text, " ")
}
