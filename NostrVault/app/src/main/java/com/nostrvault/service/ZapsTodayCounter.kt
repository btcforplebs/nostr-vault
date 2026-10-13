package com.nostrvault.service

import com.nostrvault.data.local.ConfigStore
import com.nostrvault.relay.HavenBridge
import kotlinx.serialization.json.JsonArray
import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.JsonPrimitive
import kotlinx.serialization.json.contentOrNull
import kotlinx.serialization.json.intOrNull
import kotlinx.serialization.json.longOrNull
import java.time.Instant
import java.time.ZoneId
import javax.inject.Inject
import javax.inject.Singleton

/**
 * How many zaps the active account has received since local midnight, for
 * the Vault glance widget's "Zaps today" (iOS `LockMetric.zaps`).
 *
 * Read from your own relay, which already holds the receipts sent to you:
 * no outside relay is asked. A receipt counts when it is signed, names you
 * in its `p` tag, and passes the same publisher check the Vault's Zaps list
 * uses ([ZapValidationService.isValidReceipt]), so the two agree.
 */
@Singleton
class ZapsTodayCounter @Inject constructor(
    private val nostrService: NostrService,
    private val configStore: ConfigStore,
) {
    /** Today's count for [me], or null when your relay could not be asked. */
    suspend fun count(me: String, nowMs: Long = System.currentTimeMillis()): Int? {
        if (me.isEmpty()) return 0
        val config = configStore.config.value
        // Zaps to you land in the inbox; the base path is asked too, as the
        // wallet history does (ZapHistoryService.relayUrls).
        val relays = listOfNotNull(config.localInboxURL, config.nostrURL).distinct()
        if (relays.isEmpty()) return null
        val since = ZapsToday.startOfDay(nowMs)
        val filter = """{"kinds":[${ZapsToday.RECEIPT_KIND}],"#p":["$me"],"since":$since,"limit":${ZapsToday.LIMIT}}"""
        var answered = false
        val events = nostrService.queryRawEvents(listOf(filter), relays, onAnswered = { answered = true })
        if (!answered && events.isEmpty()) return null
        val receipts = events.mapNotNull { event ->
            val receipt = ZapsToday.Receipt.from(event) ?: return@mapNotNull null
            val trusted = HavenBridge.verifyEvent(event.toString()) &&
                ZapValidationService.isValidReceipt(receipt.publisher, me, nostrService.profiles.value)
            receipt.takeIf { trusted }
        }
        return ZapsToday.count(receipts, me, since)
    }
}

/** The counting rules, apart from the relay so they can be tested. */
object ZapsToday {
    const val RECEIPT_KIND = 9735

    /** One relay answer's worth; a day with more shows this many. */
    const val LIMIT = 500

    data class Receipt(val id: String, val publisher: String, val recipients: List<String>, val createdAt: Long) {
        companion object {
            fun from(event: JsonObject): Receipt? {
                if ((event["kind"] as? JsonPrimitive)?.intOrNull != RECEIPT_KIND) return null
                val id = (event["id"] as? JsonPrimitive)?.contentOrNull ?: return null
                val publisher = (event["pubkey"] as? JsonPrimitive)?.contentOrNull ?: return null
                val createdAt = (event["created_at"] as? JsonPrimitive)?.longOrNull ?: return null
                val recipients = (event["tags"] as? JsonArray).orEmpty().mapNotNull { tag ->
                    val parts = (tag as? JsonArray)?.mapNotNull { (it as? JsonPrimitive)?.contentOrNull } ?: return@mapNotNull null
                    parts.getOrNull(1)?.takeIf { parts.firstOrNull() == "p" }
                }
                return Receipt(id, publisher, recipients, createdAt)
            }
        }
    }

    /** Local midnight at or before [nowMs], in epoch seconds. */
    fun startOfDay(nowMs: Long, zone: ZoneId = ZoneId.systemDefault()): Long =
        Instant.ofEpochMilli(nowMs).atZone(zone).toLocalDate().atStartOfDay(zone).toEpochSecond()

    /** The next local midnight after [nowMs], in epoch seconds (a 23- or 25-hour day included). */
    fun nextStartOfDay(nowMs: Long, zone: ZoneId = ZoneId.systemDefault()): Long =
        Instant.ofEpochMilli(nowMs).atZone(zone).toLocalDate().plusDays(1).atStartOfDay(zone).toEpochSecond()

    /** Receipts made out to [me] at or after [since], each counted once. */
    fun count(receipts: List<Receipt>, me: String, since: Long): Int =
        receipts.asSequence()
            .filter { it.createdAt >= since && it.recipients.any { p -> p.equals(me, ignoreCase = true) } }
            .map { it.id }
            .distinct()
            .count()
}
