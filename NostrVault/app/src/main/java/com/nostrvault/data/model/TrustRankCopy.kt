package com.nostrvault.data.model

import kotlinx.serialization.json.Json
import kotlinx.serialization.json.JsonArray
import kotlinx.serialization.json.JsonElement
import kotlinx.serialization.json.JsonNull
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
 * people who show [floor] or more are in it, plus the optional [globe] list. Scores are 0-100 on the shown
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
    /**
     * The globe list, in the file's order (empty from an engine before it).
     * Only the globe and the "how they connect" chain read it; the feed reads
     * [people] alone, through [get].
     */
    val globe: List<GlobeRow> = emptyList(),
    /**
     * The haze (`haze` in the file): for ring 3 and ring 4, the people ranked
     * after the ring's globe top, best first. Drawn only as the zoomed-out
     * ring's faint dots ([GlobeHazeField]), never tapped. Empty when the file
     * has none, or a bad one.
     */
    val haze: Map<Int, List<String>> = emptyMap(),
) {
    data class Person(val score: Double, val hop: Int)

    /** `[pubkey, shown, hop, via]`: [via] is their highest-scored follower one ring in. */
    data class GlobeRow(val pubkey: String, val score: Double, val hop: Int, val via: String)

    /** The feed's rows only. Never the globe list. */
    operator fun get(pubkey: String): Person? = people[pubkey.lowercase()]

    private val globeByKey: Map<String, GlobeRow> by lazy { globe.associateBy { it.pubkey } }

    /** A globe row by key, for the globe and the chain only. */
    fun globeRow(pubkey: String): GlobeRow? = globeByKey[pubkey.lowercase()]

    companion object {
        /** The engine's `trustrank.CeilingHop`. */
        const val CEILING_HOP = 6
        /** The engine's `trustrank.GlobeHop`: the furthest ring the globe list covers. */
        const val GLOBE_HOP = 5
        /** The engine's `trustrank.GlobePerRing`: each far ring's top, best first. */
        const val GLOBE_PER_RING = 300
        /**
         * At most this many globe rows: 9 x [GLOBE_PER_RING], because chain links
         * need links of their own (docs/MESH_COPY_V2_CONTRACT.md §5; a test reads
         * the number from there).
         */
        const val MAX_GLOBE_ROWS = 9 * GLOBE_PER_RING
        /**
         * The engine's `trustrank.HazePerRing`: the most haze rows a ring carries
         * (1,000 and 2,000 people in all, less the ring's top 300). No hop-5 haze.
         * Contract §6 says them; a test reads them from there.
         */
        val HAZE_PER_RING: Map<Int, Int> = mapOf(3 to 700, 4 to 1_700)

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
            // Optional; when it is there and wrong, the whole file is refused, as the engine does.
            val globe = when (val el = root["globe"]) {
                null, JsonNull -> emptyList()
                else -> parseGlobe(el as? JsonArray ?: return null, maxHop) ?: return null
            }
            TrustRankCopy(
                account = account,
                builtAt = builtAt,
                maxHop = maxHop,
                viewBar = prim("viewBar")?.doubleOrNull ?: 55.0,
                floor = prim("floor")?.doubleOrNull ?: 0.0,
                people = people,
                globe = globe,
                haze = parseHaze(root["haze"], maxHop, globe),
            )
        }.getOrNull()

        /**
         * The optional `haze` (haven-go `checkHaze`): rings "3" and "4" only (and
         * maxHop), each within [HAZE_PER_RING], every row a hex pubkey shown over 0
         * and at most 100, in no other ring and not a globe row. Unlike a bad globe,
         * a bad haze costs only the haze: it is empty, the copy stays.
         */
        internal fun parseHaze(el: JsonElement?, maxHop: Int, globe: List<GlobeRow>): Map<Int, List<String>> {
            val rings = el as? JsonObject ?: return emptyMap()
            val inGlobe = globe.mapTo(HashSet(globe.size * 2)) { it.pubkey }
            val seen = HashSet<String>()
            val out = HashMap<Int, List<String>>()
            for ((name, value) in rings) {
                val hop = name.toIntOrNull()?.takeIf { it.toString() == name } ?: return emptyMap()
                val cap = HAZE_PER_RING[hop] ?: return emptyMap()
                val rows = value as? JsonArray ?: return emptyMap()
                if (hop > maxHop || rows.size > cap) return emptyMap()
                val keys = ArrayList<String>(rows.size)
                for (row in rows) {
                    val cells = row as? JsonArray ?: return emptyMap()
                    if (cells.size != 2) return emptyMap()
                    val pk = (cells[0] as? JsonPrimitive)?.takeIf { it.isString }?.contentOrNull ?: return emptyMap()
                    val score = (cells[1] as? JsonPrimitive)?.takeIf { !it.isString }?.doubleOrNull ?: return emptyMap()
                    if (!isHex64(pk) || score <= 0.0 || score > 100.0 || pk in inGlobe || !seen.add(pk)) return emptyMap()
                    keys.add(pk)
                }
                out[hop] = keys
            }
            return out
        }

        /** The engine's globe check: hex keys, 0-100, rings 2 to [GLOBE_HOP] and maxHop, a hex via, at most [MAX_GLOBE_ROWS]. */
        private fun parseGlobe(rows: JsonArray, maxHop: Int): List<GlobeRow>? {
            if (rows.size > MAX_GLOBE_ROWS) return null
            val out = ArrayList<GlobeRow>(rows.size)
            for (row in rows) {
                val cells = row as? JsonArray ?: return null
                if (cells.size != 4) return null
                val pk = (cells[0] as? JsonPrimitive)?.takeIf { it.isString }?.contentOrNull ?: return null
                val score = (cells[1] as? JsonPrimitive)?.takeIf { !it.isString }?.doubleOrNull ?: return null
                val hop = (cells[2] as? JsonPrimitive)?.takeIf { !it.isString }?.intOrNull ?: return null
                val via = (cells[3] as? JsonPrimitive)?.takeIf { it.isString }?.contentOrNull ?: return null
                if (!isHex64(pk) || !isHex64(via) || score !in 0.0..100.0 || hop !in 2..minOf(GLOBE_HOP, maxHop)) return null
                out.add(GlobeRow(pk, score, hop, via))
            }
            return out
        }

        private fun isHex64(s: String) = s.length == 64 && s.all { it in '0'..'9' || it in 'a'..'f' }
    }
}
