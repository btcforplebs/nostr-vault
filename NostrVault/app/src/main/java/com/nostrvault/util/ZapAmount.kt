package com.nostrvault.util

import kotlinx.serialization.json.Json
import kotlinx.serialization.json.JsonArray
import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.JsonPrimitive

/**
 * Sats a zap receipt (kind 9735) paid: the request's `amount` tag, then the
 * receipt's own, then the paid bolt11. NIP-57 makes the request's `amount`
 * optional and many wallets leave it out, so reading only that showed real
 * zaps as 0 sats. Port of iOS LiveChat.zapAmountSats (5f866a93).
 */
object ZapAmount {
    private val json = Json { ignoreUnknownKeys = true }

    fun sats(receiptTags: List<List<String>>): Long {
        val requestTags = receiptTags.firstOrNull { it.size >= 2 && it[0] == "description" }?.get(1)
            ?.let { runCatching { json.parseToJsonElement(it) as? JsonObject }.getOrNull() }
            ?.get("tags")?.let { it as? JsonArray }
            ?.map { tag -> (tag as? JsonArray)?.mapNotNull { (it as? JsonPrimitive)?.content }.orEmpty() }
            .orEmpty()
        fun msats(tags: List<List<String>>) =
            tags.firstOrNull { it.size >= 2 && it[0] == "amount" }?.get(1)?.toLongOrNull()?.takeIf { it > 0 }
        (msats(requestTags) ?: msats(receiptTags))?.let { return it / 1000 }
        return receiptTags.firstOrNull { it.size >= 2 && it[0] == "bolt11" }?.get(1)
            ?.let { Bolt11.satsOrNull(it) } ?: 0L
    }
}
