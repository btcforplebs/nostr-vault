package com.nostrvault.util

import com.nostrvault.service.NostrEvent
import kotlinx.serialization.json.Json
import kotlinx.serialization.json.JsonArray
import kotlinx.serialization.json.JsonPrimitive
import kotlinx.serialization.json.contentOrNull
import kotlinx.serialization.json.intOrNull
import kotlinx.serialization.json.jsonObject
import kotlinx.serialization.json.longOrNull
import java.net.URI

/**
 * Relay tab > Likes / Zaps > Given: which relays to ask, and in what order the
 * posts go. Pure, so the rules are testable without the view model. Port of
 * iOS #294 (wallet history), #295 (liked posts) and #296 (local zap list,
 * receipt relays).
 */
object RelayGiven {
    val FALLBACK_FEED_RELAYS = listOf("wss://relay.primal.net", "wss://nos.lol")

    /** Liked authors' own write relays asked at most, two per author. */
    private const val MAX_AUTHOR_RELAYS = 6
    private const val AUTHOR_RELAYS_EACH = 2

    /** Relays named in a zap request, at most. */
    private const val MAX_RECEIPT_RELAYS = 10
    private const val RECIPIENT_INBOX_RELAYS = 3

    /**
     * Where to look for posts you liked that are not loaded. Your relay's root
     * holds only your own events; the posts you like are mostly other
     * people's, which the embedded relay keeps on /feed. Then the feed relays,
     * then where the liked authors themselves write.
     */
    fun likedNoteRelays(
        localRoot: String?,
        localFeed: String?,
        feedRelays: List<String>,
        missingIds: Collection<String>,
        likedAuthor: Map<String, String>,
        outboxRelays: Map<String, List<String>>,
    ): List<String> {
        val urls = mutableListOf<String>()
        localRoot?.let { urls.add(it) }
        localFeed?.let { if (it !in urls) urls.add(it) }
        for (relay in feedRelays.ifEmpty { FALLBACK_FEED_RELAYS }) if (relay !in urls) urls.add(relay)
        val authorRelays = mutableListOf<String>()
        for (id in missingIds) {
            val author = likedAuthor[id] ?: continue
            val outbox = outboxRelays[author] ?: continue
            for (relay in outbox.take(AUTHOR_RELAYS_EACH)) {
                if (relay !in urls && relay !in authorRelays) authorRelays.add(relay)
            }
        }
        return urls + authorRelays.take(MAX_AUTHOR_RELAYS)
    }

    /**
     * Where a zap's receipt should be published: the relays Given and the
     * feed read, your published inbox, and up to three of the recipient's
     * inbox relays. Your own relay is listed only when it is public: a
     * lightning provider cannot reach a loopback or LAN address.
     */
    fun zapReceiptRelays(
        ownRelay: String?,
        feedRelays: List<String>,
        myInbox: List<String>,
        recipientInbox: List<String>,
    ): List<String> {
        val candidates = listOfNotNull(ownRelay) +
            feedRelays.ifEmpty { FALLBACK_FEED_RELAYS } +
            myInbox +
            recipientInbox.take(RECIPIENT_INBOX_RELAYS)
        val seen = HashSet<String>()
        return candidates
            .map { it.trim() }
            .filter { isPublicRelay(it) && seen.add(it.lowercase().trimEnd('/')) }
            .take(MAX_RECEIPT_RELAYS)
    }

    /** False for loopback, link-local, private and LAN-only (`.local`) hosts. */
    fun isPublicRelay(url: String): Boolean {
        val host = runCatching { URI(url).host }.getOrNull()?.lowercase()?.trim('[', ']')
        if (host.isNullOrEmpty()) return false
        if (host == "localhost" || host.endsWith(".local") || host == "::1") return false
        val octets = host.split('.').mapNotNull { it.toIntOrNull() }
        if (octets.size == 4 && host.split('.').size == 4) {
            val (a, b) = octets[0] to octets[1]
            return when {
                a == 127 || a == 10 || a == 0 -> false
                a == 192 && b == 168 -> false
                a == 169 && b == 254 -> false
                a == 172 && b in 16..31 -> false
                a == 100 && b in 64..127 -> false
                else -> true
            }
        }
        return true
    }

    /**
     * When you last zapped each post, in unix seconds: the wallet's payment
     * time, or a receipt's, whichever is newer.
     */
    fun lastZapTimes(walletTimes: Map<String, Long>, receiptZaps: List<Pair<String, Long>>): Map<String, Long> {
        val times = HashMap(walletTimes)
        for ((id, at) in receiptZaps) times[id] = maxOf(times[id] ?: 0L, at)
        return times
    }

    /**
     * Newest zap first, so a post moves to the top when a zap on it comes in.
     * A post with no known zap time (one only this app's list knows about)
     * stands in with its own time.
     */
    fun <T> newestZapFirst(
        items: List<T>,
        lastZapAt: Map<String, Long>,
        id: (T) -> String,
        createdAt: (T) -> Long,
    ): List<T> = items.sortedWith(
        compareByDescending<T> { lastZapAt[id(it)] ?: createdAt(it) }.thenByDescending { createdAt(it) },
    )

    /**
     * Sats you paid each post. The wallet's own history wins over this app's
     * record of what it zapped; a zero amount is unknown, not zero.
     */
    fun givenAmounts(localZapped: Map<String, Int>, walletAmounts: Map<String, Long>): Map<String, Long> {
        val amounts = HashMap<String, Long>()
        for ((id, sats) in localZapped) if (sats > 0) amounts[id] = sats.toLong()
        amounts.putAll(walletAmounts)
        return amounts
    }

    /**
     * Parses a signed event as relays send it. Null unless every field is
     * there, so a cached half-event never stands in for a post.
     */
    fun eventFromJson(json: String): NostrEvent? = runCatching {
        val o = Json.parseToJsonElement(json).jsonObject
        fun str(key: String) = (o[key] as? JsonPrimitive)?.contentOrNull
        val tags = (o["tags"] as? JsonArray)?.map { tag ->
            (tag as JsonArray).map { (it as JsonPrimitive).content }
        } ?: return@runCatching null
        NostrEvent(
            id = str("id") ?: return@runCatching null,
            pubkey = str("pubkey") ?: return@runCatching null,
            createdAt = (o["created_at"] as? JsonPrimitive)?.longOrNull ?: return@runCatching null,
            kind = (o["kind"] as? JsonPrimitive)?.intOrNull ?: return@runCatching null,
            tags = tags,
            content = str("content") ?: return@runCatching null,
            sig = str("sig") ?: return@runCatching null,
        )
    }.getOrNull()
}
