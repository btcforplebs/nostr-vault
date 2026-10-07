package com.nostrvault.service

import com.nostrvault.data.local.ConfigStore
import com.nostrvault.data.model.FeedNote
import com.nostrvault.relay.HavenBridge
import com.nostrvault.util.WalletTransaction
import com.nostrvault.util.ZapDetail
import com.nostrvault.util.ZapDetail.Companion.parseTags
import com.nostrvault.util.ZapReceipt
import kotlinx.serialization.json.JsonObject
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
        //    network at all. The payer wrote that request, so it is believed
        //    only with a valid signature.
        val details = LinkedHashMap<String, ZapDetail>()
        for (tx in transactions) {
            val zap = tx.zap ?: continue
            val json = zap.requestJson ?: continue
            if (HavenBridge.verifyEvent(json) && fits(zap, tx, me)) details[tx.id] = zap
        }

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
            val receipts = nostrService.queryRawEvents(filters, relays).mapNotNull { trustedReceipt(it) }
            val byTx = unresolved.associateBy { it.id }
            for ((id, zap) in ZapReceipt.match(unresolved, receipts)) {
                val tx = byTx[id] ?: continue
                if (fits(zap, tx, me)) details.putIfAbsent(id, zap)
            }
        }

        // 3. The zapped posts, for the "on: …" line and tap-to-open.
        val posts = HashMap<String, FeedNote>()
        val postIds = details.values.mapNotNull { it.postId }.distinct()
            .filter { it.length == 64 && it.all { c -> c in '0'..'9' || c in 'a'..'f' } }
        if (postIds.isNotEmpty()) {
            val ids = postIds.joinToString(",") { "\"$it\"" }
            val wanted = postIds.toSet()
            for (e in nostrService.queryRawEvents(listOf("""{"ids":[$ids],"limit":${postIds.size}}"""), relays)) {
                val id = e["id"].string() ?: continue
                // Shown as that author's post, and cached for the note screen.
                if (id !in wanted || !HavenBridge.verifyEvent(e.toString())) continue
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
     * A receipt is anyone's event until proven otherwise. Believed only when
     * it is signed, the zap request inside it is signed, and it was published
     * by the key the zapped person's own LNURL service names (`nostrPubkey`).
     * Without the last check, anyone could copy a real receipt's bolt11 into
     * one of their own and put any sender, post or comment ("refund me at …")
     * on your payment.
     */
    private suspend fun trustedReceipt(event: JsonObject): ZapReceipt? {
        if ((event["kind"] as? JsonPrimitive)?.intOrNull != 9735) return null
        val publisher = event["pubkey"].string() ?: return null
        val receipt = ZapReceipt.fromTags(parseTags(event["tags"])) ?: return null
        val requestJson = receipt.detail.requestJson ?: return null
        val recipient = receipt.detail.recipientPubkey ?: return null
        if (!HavenBridge.verifyEvent(event.toString()) || !HavenBridge.verifyEvent(requestJson)) return null
        val authorized = ZapValidationService.authorizedPublisher(recipient, nostrService.profiles.value) ?: return null
        return receipt.takeIf { authorized.equals(publisher, ignoreCase = true) }
    }

    /**
     * A zap you received was made out to you; one you sent was made by you (or
     * anonymously, from a throwaway key).
     */
    private fun fits(zap: ZapDetail, tx: WalletTransaction, me: String): Boolean = when (tx.direction) {
        WalletTransaction.Direction.INCOMING -> zap.recipientPubkey.equals(me, ignoreCase = true)
        WalletTransaction.Direction.OUTGOING -> zap.isAnonymous || zap.senderPubkey.equals(me, ignoreCase = true)
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
            addAll(config.readRelays)
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
