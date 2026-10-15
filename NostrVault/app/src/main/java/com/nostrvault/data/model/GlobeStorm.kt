package com.nostrvault.data.model

import kotlinx.serialization.json.Json
import kotlinx.serialization.json.JsonArray
import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.JsonPrimitive
import kotlinx.serialization.json.buildJsonArray
import kotlinx.serialization.json.buildJsonObject
import kotlinx.serialization.json.put
import kotlin.math.roundToInt

/**
 * The storm: every arrival on the globe at once, in real time (iOS
 * `GlobeStorm.swift`). What lets hundreds of lines fly without the phone
 * choking: how busy counts as busy, how many get faces, how lines are drawn in a
 * few batches, and how the globe's REQs share the feed's open connections.
 */
object GlobeStorm {
    /** From this many lines in flight the globe draws at full frame rate; below it, 30 fps. */
    const val BUSY_LINES = 12
    /** People pictured at the ends of lines. The rest stay stars. */
    const val MAX_ARC_FACES = 24
    /** In a storm the faces change at most this often (seconds): each change lays out pictures. */
    const val FACE_REFRESH = 0.5

    // ── Batched drawing ──

    /** Opacity steps lines are drawn in. Lines at the same step share one path. */
    const val ALPHA_BANDS = 12

    /** The step an opacity is drawn at; 0 for nothing to draw. */
    fun band(alpha: Double): Int {
        if (alpha <= 0.01) return 0
        return (alpha * ALPHA_BANDS).roundToInt().coerceIn(1, ALPHA_BANDS)
    }

    /** The opacity a step is drawn with. */
    fun bandAlpha(band: Int): Double = band.toDouble() / ALPHA_BANDS

    /** Points along a drawn trail: smooth for a few lines, fewer in a storm. */
    fun arcSamples(lines: Int) = if (lines > 60) 16 else 40

    // ── Sharing the feed's connections ──

    /**
     * Every globe subscription id starts with this. The feed skips messages
     * under it on the connections they share, so a Global star never lands in
     * the feed or in your relay.
     */
    const val SUBSCRIPTION_PREFIX = "arcs-"

    private val json = Json { ignoreUnknownKeys = true }

    /**
     * True for a relay message (`EVENT`, `EOSE`, `CLOSED`) that answers one of
     * the globe's subscriptions. Parsed as JSON, not matched on its head: a relay
     * may put any whitespace between the tokens, or escape the sub id, and a
     * globe EVENT missed here would go into the feed and your relay.
     */
    fun isGlobeMessage(message: String): Boolean {
        val array = runCatching { json.parseToJsonElement(message) as? JsonArray }.getOrNull() ?: return false
        if (array.size < 2) return false
        val type = (array[0] as? JsonPrimitive)?.takeIf { it.isString }?.content ?: return false
        val id = (array[1] as? JsonPrimitive)?.takeIf { it.isString }?.content ?: return false
        return isGlobeSubscription(type, id)
    }

    /** The same test on a message already parsed into its type and sub id (the feed's own parse). */
    fun isGlobeSubscription(type: String, subId: String): Boolean =
        (type == "EVENT" || type == "EOSE" || type == "CLOSED") && subId.startsWith(SUBSCRIPTION_PREFIX)

    /** The sub id of a REQ message, or null. */
    fun subscriptionOf(request: String): String? {
        val array = runCatching { json.parseToJsonElement(request) as? JsonArray }.getOrNull() ?: return null
        if ((array.getOrNull(0) as? JsonPrimitive)?.content != "REQ") return null
        return (array.getOrNull(1) as? JsonPrimitive)?.takeIf { it.isString }?.content
    }

    /** The `CLOSE` messages that end [requests]' subscriptions: only the globe's own, never the feed's. */
    fun closes(requests: List<String>): List<String> = requests.mapNotNull { request ->
        val id = subscriptionOf(request)?.takeIf { it.startsWith(SUBSCRIPTION_PREFIX) } ?: return@mapNotNull null
        buildJsonArray { add(JsonPrimitive("CLOSE")); add(JsonPrimitive(id)) }.toString()
    }

    /**
     * The globe's filters on one read relay. Discover and Global are one filter
     * with no authors, the relay's whole live stream: every note is sorted to its
     * feed by its author here, so the whole of your wider web is in it and it
     * costs one subscription however big the web is. Your follows alone keep to
     * their authors, a filter of up to [authorsPerFilter] each.
     */
    fun storm(
        rings: Set<GlobeArcs.Ring>,
        show: GlobeLive.Show,
        follows: List<String>,
        since: Long,
        authorsPerFilter: Int = AUTHORS_PER_FILTER,
    ): List<JsonObject> {
        val kinds = show.wideKinds
        // An empty kinds list would match everything on some relays.
        if (kinds.isEmpty() || rings.isEmpty()) return emptyList()
        fun filter(authors: List<String>?) = buildJsonObject {
            put("kinds", JsonArray(kinds.map { JsonPrimitive(it) }))
            put("since", since)
            if (authors != null) put("authors", JsonArray(authors.map { JsonPrimitive(it) }))
        }
        if (GlobeArcs.Ring.DISCOVER in rings || GlobeArcs.Ring.GLOBAL in rings) return listOf(filter(null))
        return follows.chunked(authorsPerFilter).map { filter(it) }
    }

    /** Most authors one filter names (iOS `GlobeArrivalStream.authorsPerFilter`). */
    const val AUTHORS_PER_FILTER = 500
}
