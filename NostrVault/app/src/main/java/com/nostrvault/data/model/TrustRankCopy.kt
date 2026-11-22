package com.nostrvault.data.model

import kotlinx.serialization.json.Json
import kotlinx.serialization.json.JsonArray
import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.JsonPrimitive
import kotlinx.serialization.json.contentOrNull
import kotlinx.serialization.json.doubleOrNull
import kotlinx.serialization.json.intOrNull
import kotlinx.serialization.json.longOrNull

/**
 * The Haven's trust rank for one account, as this phone keeps it
 * (`wot_rank_<account>.json` next to the WoT cache; the engine's catch-up
 * writes it, haven-go `copyv2_trust.go`). Only the account's follows and
 * people who show [floor] or more are in it. Scores are 0-100 on the shown
 * scale; hops are true follow distances, 1 to 6.
 *
 * A phone with no Haven has no file, and so no scores (Logen 2026-11-22).
 */
data class TrustRankCopy(
    val account: String,
    /** Unix seconds: when the Haven ranked. The file's age. */
    val builtAt: Long,
    /** The furthest ring the Haven's pass reached. */
    val maxHop: Int,
    /** Where the slider starts (shown scale). */
    val viewBar: Double,
    /** People under this did not travel. */
    val floor: Double,
    val people: Map<String, Person>,
) {
    data class Person(val score: Double, val hop: Int)

    operator fun get(pubkey: String): Person? = people[pubkey.lowercase()]

    companion object {
        /** The engine's `trustrank.CeilingHop`. */
        const val CEILING_HOP = 6

        private val json = Json { ignoreUnknownKeys = true }

        /**
         * The file, when it is [account]'s, version 2, and every row is a hex
         * pubkey with a 0-100 score in rings 1 to maxHop. Anything else is
         * null: the same checks the engine made before keeping it
         * (`trustrank.CheckHandoff`), made again because a file on disk is
         * only as good as whoever wrote it last.
         */
        fun parse(text: String, account: String): TrustRankCopy? = runCatching {
            val root = json.parseToJsonElement(text) as? JsonObject ?: return null
            // Numbers, not numbers in quotes, as the engine reads them.
            fun prim(key: String) = (root[key] as? JsonPrimitive)?.takeIf { !it.isString || key == "account" }
            if (prim("account")?.contentOrNull != account || prim("version")?.intOrNull != 2) return null
            val builtAt = prim("builtAt")?.longOrNull?.takeIf { it > 0 } ?: return null
            val maxHop = prim("maxHop")?.intOrNull?.takeIf { it in 1..CEILING_HOP } ?: return null
            val rows = root["people"] as? JsonArray ?: return null
            val people = HashMap<String, Person>(rows.size * 2)
            for (row in rows) {
                val cells = row as? JsonArray ?: return null
                if (cells.size != 3) return null
                val pk = (cells[0] as? JsonPrimitive)?.contentOrNull ?: return null
                // Numbers, not numbers in quotes: the engine's file never quotes them.
                val score = (cells[1] as? JsonPrimitive)?.takeIf { !it.isString }?.doubleOrNull ?: return null
                val hop = (cells[2] as? JsonPrimitive)?.takeIf { !it.isString }?.intOrNull ?: return null
                if (!isHex64(pk) || score !in 0.0..100.0 || hop !in 1..maxHop) return null
                people[pk] = Person(score, hop)
            }
            TrustRankCopy(
                account = account,
                builtAt = builtAt,
                maxHop = maxHop,
                viewBar = prim("viewBar")?.doubleOrNull ?: 55.0,
                floor = prim("floor")?.doubleOrNull ?: 0.0,
                people = people,
            )
        }.getOrNull()

        private fun isHex64(s: String) = s.length == 64 && s.all { it in '0'..'9' || it in 'a'..'f' }
    }
}
