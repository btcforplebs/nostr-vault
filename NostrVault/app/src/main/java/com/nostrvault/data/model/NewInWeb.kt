package com.nostrvault.data.model

import kotlinx.serialization.json.Json
import kotlinx.serialization.json.JsonArray
import kotlinx.serialization.json.JsonPrimitive
import kotlinx.serialization.json.buildJsonObject
import kotlinx.serialization.json.jsonArray
import kotlinx.serialization.json.jsonObject
import kotlinx.serialization.json.jsonPrimitive
import kotlinx.serialization.json.long
import kotlinx.serialization.json.put

/**
 * Who is new in your web, for My Web: the twin of iOS `WotNewcomers` (here that
 * name is the relay rebuild's count, [WotRefreshProgress]), and of the
 * web's `newInWeb` (web-vault/src/desktop/space/wot-mini.js). People your
 * follows have come to vouch for since this device last looked; someone stays
 * new for a week while still vouched for. A first look only notes everyone.
 * Known people are never forgotten, so someone a missing list hides for a
 * while doesn't come back as new.
 */
data class NewInWeb(
    /** First 8 hex characters of everyone seen in the web. */
    val known: Set<String> = emptySet(),
    /** Newcomers and when this device first saw them, newest first. */
    val fresh: List<Fresh> = emptyList(),
) {
    data class Fresh(val pubkey: String, val at: Long)

    /** The same shape as iOS's Codable form. */
    fun toJson(): String = buildJsonObject {
        put("known", JsonArray(known.sorted().map(::JsonPrimitive)))
        put("fresh", JsonArray(fresh.map { buildJsonObject { put("pubkey", it.pubkey); put("at", it.at) } }))
    }.toString()

    companion object {
        const val FACES = 6
        const val NEW_FOR = 7L * 86400
        const val KEPT = 40

        private fun short(pk: String) = pk.take(8)

        /**
         * [allVouched]: the web's extended layer, most linked first. [kept] null on a first look.
         * Anyone in [muted] (the mute list, kind 10000, public and private) is never offered and
         * never newly noted, and drops out of new once muted, as the web's `newInWeb`.
         */
        fun update(allVouched: List<String>, kept: NewInWeb?, now: Long, muted: Set<String> = emptySet()): NewInWeb {
            val vouched = if (muted.isEmpty()) allVouched else allVouched.filter { it !in muted }
            if (kept == null) return NewInWeb(known = vouched.mapTo(HashSet(), ::short))
            val still = vouched.toHashSet()
            val stillFresh = kept.fresh.filter { it.pubkey in still && now - it.at < NEW_FOR }
            val had = stillFresh.mapTo(HashSet()) { it.pubkey }
            val arrived = vouched.filter { short(it) !in kept.known && it !in had }.map { Fresh(it, now) }
            return NewInWeb(
                known = kept.known + vouched.map(::short),
                fresh = (arrived + stillFresh).take(KEPT),
            )
        }

        fun key(owner: String) = "nv-wot-seen:$owner"

        /** Null for nothing kept, or anything that doesn't read: a first look. */
        fun fromJson(text: String?): NewInWeb? = text?.let {
            runCatching {
                val obj = Json.parseToJsonElement(it).jsonObject
                NewInWeb(
                    known = obj["known"]!!.jsonArray.mapTo(HashSet()) { e -> e.jsonPrimitive.content },
                    fresh = obj["fresh"]!!.jsonArray.map { e ->
                        val f = e.jsonObject
                        Fresh(f["pubkey"]!!.jsonPrimitive.content, f["at"]!!.jsonPrimitive.long)
                    },
                )
            }.getOrNull()
        }
    }
}
