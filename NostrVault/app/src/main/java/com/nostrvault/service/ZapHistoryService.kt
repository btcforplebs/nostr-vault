package com.nostrvault.service

import com.nostrvault.data.local.ConfigStore
import com.nostrvault.data.model.FeedNote
import com.nostrvault.util.WalletTransaction
import com.nostrvault.util.ZapDetail
import com.nostrvault.util.ZapDetail.Companion.parseTags
import com.nostrvault.util.ZapReceipt
import kotlinx.serialization.json.JsonPrimitive
import kotlinx.serialization.json.contentOrNull
import kotlinx.serialization.json.intOrNull
import kotlinx.serialization.json.longOrNull
import javax.inject.Inject
import javax.inject.Singleton

/**
 * Finds the zap receipts (and the zapped posts) behind wallet history rows,
 * so a row can say who a zap was from and what it was for.
 *
 * Receipts are public kind-9735 events: incoming ones tag you with `p`,
 * outgoing ones with `P` (the sender). They are fetched once per history
 * page from your own relay, your feed relays and your inbox relays, then
 * matched to transactions by payment hash ([ZapReceipt.match]).
 *
 * Port of iOS ZapHistoryService.swift.
 */
@Singleton
class ZapHistoryService @Inject constructor(
    private val nostrService: NostrService,
    private val feedService: FeedService,
    private val configStore: ConfigStore,
) {
    data class Result(
        /** Transaction id -> zap. */
        val details: Map<String, ZapDetail> = emptyMap(),
        /** Post id -> post. */
        val posts: Map<String, FeedNote> = emptyMap(),
    )

    suspend fun lookup(transactions: List<WalletTransaction>, me: String): Result {
        if (me.isEmpty() || transactions.isEmpty()) return Result()

        // 1. Wallets that return the zap request as the description need no
        //    network at all.
        val details = LinkedHashMap<String, ZapDetail>()
        for (tx in transactions) tx.zap?.let { details[tx.id] = it }

        val relays = relayUrls(me)

        // 2. Receipts for the rest, over the time span the page covers.
        val unresolved = transactions.filter { it.id !in details }
        if (unresolved.isNotEmpty()) {
            // Receipts are published when the invoice is paid, which can be a
            // while after it was created.
            val since = unresolved.minOf { it.createdAt } - 600
            val until = unresolved.maxOf { it.createdAt } + 3_600
            val filters = listOf("#p", "#P").map { tag ->
                """{"kinds":[9735],"$tag":["$me"],"since":$since,"until":$until,"limit":500}"""
            }
            val receipts = nostrService.queryRawEvents(filters, relays)
                .mapNotNull { ZapReceipt.fromTags(parseTags(it["tags"])) }
            for ((id, zap) in ZapReceipt.match(unresolved, receipts)) details.putIfAbsent(id, zap)
        }

        // 3. The zapped posts, for the "on: …" line and tap-to-open.
        val posts = HashMap<String, FeedNote>()
        val postIds = details.values.mapNotNull { it.postId }.distinct()
            .filter { it.length == 64 && it.all { c -> c in '0'..'9' || c in 'a'..'f' } }
        if (postIds.isNotEmpty()) {
            val ids = postIds.joinToString(",") { "\"$it\"" }
            for (e in nostrService.queryRawEvents(listOf("""{"ids":[$ids],"limit":${postIds.size}}"""), relays)) {
                val id = e["id"].string() ?: continue
                val pubkey = e["pubkey"].string() ?: continue
                val kind = (e["kind"] as? JsonPrimitive)?.intOrNull ?: continue
                val createdAt = (e["created_at"] as? JsonPrimitive)?.longOrNull ?: continue
                val note = FeedNote.fromEvent(id, pubkey, e["content"].string() ?: "", parseTags(e["tags"]), createdAt, kind)
                posts[id] = note
                // So the note-detail screen opens it from memory instead of
                // fetching it again.
                if (kind == 1) {
                    feedService.cacheNote(note)
                    feedService.cacheRawEvent(id, e.toString())
                }
            }
        }

        // 4. Names and pictures for everyone involved.
        val people = transactions.mapNotNull { tx -> details[tx.id]?.counterparty(me, tx.direction) }
        val authors = posts.values.map { it.pubkey }
        val missing = (people + authors).distinct()
        if (missing.isNotEmpty()) nostrService.fetchMissingProfiles(missing)

        return Result(details, posts)
    }

    /**
     * Your relay first (it is local and holds what was sent to you), then
     * the relays you read the feed from, then your published inbox relays.
     */
    private fun relayUrls(me: String): List<String> {
        val config = configStore.config.value
        val candidates = buildList {
            config.nostrURL?.let { add(it) }
            // Zaps to you land in the local relay's inbox, not its base path.
            config.localInboxURL?.let { add(it) }
            addAll(config.activeFeedRelays.ifEmpty { listOf("wss://relay.primal.net", "wss://nos.lol") })
            addAll(nostrService.relayLists.value[me].orEmpty())
        }
        val seen = HashSet<String>()
        return candidates
            .map { it.trim() }
            .filter { it.isNotEmpty() && seen.add(it.lowercase().trimEnd('/')) }
            .take(8)
    }

    private fun kotlinx.serialization.json.JsonElement?.string(): String? =
        (this as? JsonPrimitive)?.takeIf { it.isString }?.contentOrNull
}
