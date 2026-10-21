package com.nostrvault.data.model

import kotlinx.serialization.json.Json
import kotlinx.serialization.json.JsonArray
import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.JsonPrimitive
import kotlinx.serialization.json.buildJsonObject
import kotlinx.serialization.json.doubleOrNull
import kotlinx.serialization.json.intOrNull
import kotlinx.serialization.json.longOrNull
import kotlin.math.PI
import kotlin.math.abs
import kotlin.math.floor
import kotlin.math.log10
import kotlin.math.sin

/**
 * Zaps on the WOT globe (iOS `GlobeZaps.swift`): a lightning bolt from the
 * zapper to the person zapped, a quick jagged flash with a short afterglow,
 * unlike a note's star.
 */
object GlobeZaps {
    /** The zap request the receipt carries in its `description` tag. */
    const val ZAP_REQUEST_KIND = 9734
    /** The bolt strikes across in this long, */
    const val BOLT_STRIKE = 0.12
    /** stays at full flash this long, */
    const val BOLT_FLASH = 0.35
    /** and its afterglow fades over this long. */
    const val BOLT_GLOW = 1.4
    const val BOLT_LIFE = BOLT_STRIKE + BOLT_FLASH + BOLT_GLOW

    private val json = Json { ignoreUnknownKeys = true }

    /**
     * A zap receipt as a bolt from the zapper to the person zapped. The receipt's
     * own pubkey is the LNURL server, so the zapper is the zap request's
     * (`description`, kind 9734) pubkey. Receipts can be forged: one whose request
     * doesn't parse, isn't a 9734, names someone other than the receipt's `p`, or
     * fails [verify] (its id and signature, checked on the request as read here,
     * rebuilt) draws nothing. Without the check anyone could draw a bolt from
     * anyone, or pass a stranger off as a follow past Global's trust filter.
     */
    fun zap(event: JsonObject, nowSeconds: Double, verify: (String) -> Boolean): GlobeArcs.Arrival? {
        if ((event["kind"] as? JsonPrimitive)?.intOrNull != GlobeArcs.ZAP_KIND) return null
        val id = (event["id"] as? JsonPrimitive)?.takeIf { it.isString }?.content?.lowercase() ?: return null
        if (!GlobeArcs.isKey(id)) return null
        val created = (event["created_at"] as? JsonPrimitive)?.doubleOrNull
        if (created != null && nowSeconds - created > GlobeArcs.MAX_AGE) return null
        val tags = GlobeArcs.tags(event["tags"])
        fun values(name: String, tags: List<List<String>>) = tags.filter { it.size >= 2 && it[0] == name }.map { it[1].lowercase() }
        val recipients = values("p", tags)
        if (recipients.size != 1) return null
        val recipient = recipients[0].takeIf(GlobeArcs::isKey) ?: return null
        val description = tags.firstOrNull { it.size >= 2 && it[0] == "description" }?.get(1) ?: return null
        val request = runCatching { json.parseToJsonElement(description) as? JsonObject }.getOrNull() ?: return null
        if ((request["kind"] as? JsonPrimitive)?.intOrNull != ZAP_REQUEST_KIND) return null
        val zapper = (request["pubkey"] as? JsonPrimitive)?.takeIf { it.isString }?.content ?: return null
        if (!GlobeArcs.isKey(zapper) || zapper != zapper.lowercase()) return null
        val requestTags = (request["tags"] as? JsonArray)?.let { GlobeArcs.tags(it) } ?: return null
        if (values("p", requestTags) != listOf(recipient) || zapper == recipient) return null
        // Last, as the one costly check: the request is the zapper's own. It is
        // checked as read here, rebuilt from the fields above, never as the raw
        // text: JSON with a key twice could read one way here and another in the
        // verifier, so the raw text could prove one zapper while another is drawn.
        val signed = canonicalRequest(request) ?: return null
        if (!verify(signed)) return null
        // The amount the zapper signed for (msats), for how hard it strikes.
        val msats = requestTags.firstOrNull { it.size >= 2 && it[0] == "amount" }?.get(1)?.toLongOrNull() ?: 0L
        return GlobeArcs.Arrival(id, zapper, listOf(recipient), sort = GlobeArcs.Sort.ZAP,
            strength = zapStrength(msats / 1000))
    }

    /**
     * A zap request rebuilt from this reading of it, with exactly the NIP-01
     * fields in sorted order, for the signature check. Null unless every field is
     * there with its proper type: a 64-hex id and pubkey, string tags and content,
     * a sig, and a whole-number created_at. A whole number written as a float
     * (`1799999990.0`, `1.79999999e9`) is taken as that integer and rendered
     * plainly, as the verifier reads it; a fractional one is refused.
     */
    fun canonicalRequest(request: JsonObject): String? {
        fun string(key: String) = (request[key] as? JsonPrimitive)?.takeIf { it.isString }?.content
        val id = string("id")?.takeIf(GlobeArcs::isKey) ?: return null
        val pubkey = string("pubkey")?.takeIf(GlobeArcs::isKey) ?: return null
        val createdPrimitive = (request["created_at"] as? JsonPrimitive)?.takeIf { !it.isString } ?: return null
        val created = createdPrimitive.longOrNull
            ?: createdPrimitive.doubleOrNull?.takeIf { it == floor(it) && abs(it) < 9.0e15 }?.toLong()
            ?: return null
        val kind = (request["kind"] as? JsonPrimitive)?.takeIf { !it.isString }?.intOrNull ?: return null
        val tagsElement = request["tags"] as? JsonArray ?: return null
        val tags = tagsElement.map { tag ->
            (tag as? JsonArray)?.map { (it as? JsonPrimitive)?.takeIf { p -> p.isString }?.content ?: return null } ?: return null
        }
        val content = string("content") ?: return null
        val sig = string("sig") ?: return null
        return buildJsonObject {
            put("content", JsonPrimitive(content))
            put("created_at", JsonPrimitive(created))
            put("id", JsonPrimitive(id))
            put("kind", JsonPrimitive(kind))
            put("pubkey", JsonPrimitive(pubkey))
            put("sig", JsonPrimitive(sig))
            put("tags", JsonArray(tags.map { tag -> JsonArray(tag.map { JsonPrimitive(it) }) }))
        }.toString()
    }

    /**
     * How hard a zap's bolt strikes, 0.15 to 1, by sats on a log scale: 21 sats
     * a light flick, 1,000 a solid strike, 100,000 and up the most. A zap whose
     * amount isn't known strikes lightly.
     */
    fun zapStrength(sats: Long): Double {
        if (sats <= 1) return 0.15
        return (log10(sats.toDouble()) / 5).coerceIn(0.15, 1.0)
    }

    /**
     * A bolt's moment: head how far it has struck across, then a full flash, then
     * an afterglow fading out. Reduce Motion: there at once, one steady line that fades.
     */
    fun boltStage(line: GlobeArcs.Line, now: Double, reduceMotion: Boolean = false): GlobeArcs.Stage {
        val age = maxOf(0.0, now - line.born)
        val head = if (reduceMotion) 1.0 else minOf(1.0, age / BOLT_STRIKE)
        val lit = BOLT_STRIKE + BOLT_FLASH
        var alpha = if (age <= lit) 1.0 else 1 - minOf(1.0, (age - lit) / BOLT_GLOW)
        alpha *= alpha
        line.retired?.let { retired ->
            alpha = minOf(alpha, 1 - minOf(1.0, maxOf(0.0, now - retired) / GlobeArcs.RETIRE_FADE))
        }
        val landing = if (reduceMotion) 0.0 else ((age - BOLT_STRIKE) / BOLT_FLASH).coerceIn(0.0, 1.0)
        return GlobeArcs.Stage(head, alpha, maxOf(0.0, alpha), landing)
    }

    /** True while the bolt still flickers: during its flash, not its afterglow. */
    fun boltFlickers(line: GlobeArcs.Line, now: Double) = now - line.born < BOLT_STRIKE + BOLT_FLASH
}

/**
 * The bolt's jagged shape (iOS `GlobeBolt`): sideways offsets along it, as
 * fractions of its length, and one short fork. Pinned at both ends, widest in
 * the middle, and the same for the same zap and flicker frame, so a frame drawn
 * twice draws the same bolt. 64-bit arithmetic wraps as Swift's `&*` does.
 */
object GlobeBolt {
    /** Points along a bolt. */
    const val SEGMENTS = 14
    /** New shapes a second while it flashes. */
    const val FLICKER_RATE = 16.0
    /** Widest sideways reach, as a fraction of its length. */
    const val REACH = 0.07

    /** A stable seed from a zap's id (FNV-1a). */
    fun seed(id: String): Long =
        id.toByteArray().fold(-0x340d631b7bdddcdbL) { h, b -> (h xor (b.toLong() and 0xff)) * 0x100000001b3L }

    /** The flicker frame at a time; one frame for good once it stops. */
    fun frame(age: Double, flickers: Boolean): Int = if (flickers) (age * FLICKER_RATE).toInt() else -1

    private class Random(var state: Long) {
        fun next(): Double {
            state += -0x61c8864680b583ebL
            var z = state
            z = (z xor (z ushr 30)) * -0x40a7b892e31b1a47L
            z = (z xor (z ushr 27)) * -0x6b2fb644ecceee15L
            z = z xor (z ushr 31)
            return (z ushr 11).toDouble() / (1L shl 53).toDouble() * 2 - 1
        }
    }

    /** SEGMENTS + 1 offsets, 0 at both ends. Reduce Motion: all 0, a plain line. */
    fun offsets(seed: Long, frame: Int, reduceMotion: Boolean): List<Double> {
        if (reduceMotion) return List(SEGMENTS + 1) { 0.0 }
        val random = Random(seed xor (frame.toLong() * -0x2917014799a6026dL))
        return (0..SEGMENTS).map { i ->
            if (i == 0 || i == SEGMENTS) 0.0 else random.next() * REACH * sin(i.toDouble() / SEGMENTS * PI)
        }
    }

    data class Fork(val from: Int, val turn: Double, val length: Double)

    /** One fork, or two for a strong zap, each from its own point. */
    fun forks(seed: Long, strength: Double): List<Fork> =
        (0 until (if (strength >= 0.5) 2 else 1)).map { fork(seed + it.toLong() * -0x61c8864680b583ebL) }

    /** How bright the bolt is this flicker frame, 0.55 to 1: it stutters while it flashes. */
    fun flicker(seed: Long, frame: Int): Double {
        if (frame < 0) return 1.0
        val random = Random(seed xor (frame.toLong() * -0x5db4512b69c11bf9L))
        return 0.775 + 0.225 * random.next()
    }

    /** The fork: which point it leaves from, its turn off the bolt (radians) and its length as a fraction of the bolt's. */
    fun fork(seed: Long): Fork {
        val random = Random(seed * 0x2545f4914f6cdd1dL)
        val from = SEGMENTS / 3 + ((random.next() + 1) / 2 * (SEGMENTS / 3)).toInt()
        val sign = if (random.next() >= 0) 1 else -1
        val turn = sign * (0.45 + 0.25 * abs(random.next()))
        return Fork(from, turn, 0.16 + 0.08 * abs(random.next()))
    }
}
