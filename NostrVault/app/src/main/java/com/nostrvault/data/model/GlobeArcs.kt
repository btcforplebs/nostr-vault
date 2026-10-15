package com.nostrvault.data.model

import kotlinx.serialization.json.JsonArray
import kotlinx.serialization.json.JsonElement
import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.JsonPrimitive
import kotlinx.serialization.json.buildJsonArray
import kotlinx.serialization.json.doubleOrNull
import kotlinx.serialization.json.intOrNull

/**
 * Live arrival arcs on the Web of Trust globe (iOS `GlobeArcs.swift`). Every
 * note reaching the relay flies a star. A reply, quote or repost flies between
 * its two parties: from its author to each person it is aimed at. A note aimed
 * at no one flies into you at the center. Where a star sets out says which feed
 * it came from: your follows from the ring, Discover from the next shell out,
 * Global from the outer haze.
 */
object GlobeArcs {
    /**
     * Most lines on the globe at once: high enough that a busy network reads as
     * a storm, low enough that the phone keeps drawing smoothly. Past it the
     * widest feed's oldest lines are sent on their way out early, Global first.
     */
    const val MAX_LINES = 300
    /** People one note draws lines to: a reply to a crowd stays a few lines. */
    const val MAX_TARGETS = 4
    /** A star travels from its author to its target over this long, */
    const val TRAVEL = 2.0
    /** its faint trail fades this long after it lands, */
    const val TRAIL_FADE = 1.2
    /** and the light where it landed stays this long */
    const val HOLD = 2.6
    /** and fades over this long. */
    const val FADE = 2.2
    /** How much of the line, behind the star, its tail covers. */
    const val TAIL_LENGTH = 0.16
    /** A line sent out early to make room fades this fast. */
    const val RETIRE_FADE = 0.7
    /** A note older than this (seconds) when it arrives is a relay catching up, not an arrival. */
    const val MAX_AGE = 180.0
    /**
     * Notes, replies and quotes, and NIP-22 comments: some clients send a reply
     * to a note as a kind 1111 comment, and the feed takes them in.
     */
    val KINDS = listOf(1, NIP10Thread.COMMENT_KIND)
    /** Reposts (kind 6) and generic reposts (kind 16): the reposter to the person reposted. */
    val REPOST_KINDS = listOf(6, 16)
    /** NIP-57 zap receipts. Drawn as bolts by the next change; until then they never fly. */
    const val ZAP_KIND = 9735

    /** The feed a note came in on, which sets where its star starts. */
    enum class Ring(val title: String) {
        FOLLOWING("Following"), DISCOVER("Discover"), GLOBAL("Global");

        /** Off the globe, an author's star starts on this shell. Your follows start on the ring. */
        val radius: Double
            get() = when (this) {
                FOLLOWING -> TrustMap.RING_RADIUS
                DISCOVER -> TrustMap.CLOSE_RADIUS
                GLOBAL -> TrustMap.OUTER_RADIUS
            }
    }

    /** One note: who wrote it, who it is aimed at, and the feed it came in on. */
    data class Arrival(
        val id: String,
        val author: String,
        val targets: List<String>,
        val ring: Ring = Ring.FOLLOWING,
        /** What it is, for the live switches ([GlobeLive]). */
        val sort: Sort = Sort.NOTE,
    )

    /** What an arrival is (iOS `GlobeArcs.Sort`). */
    enum class Sort { NOTE, REPLY, REPOST, REACTION, ZAP }

    /**
     * An arrival from a relay event's fields: its `p` tags in order, once each,
     * without the author. Null for anything that isn't a fresh note, reply,
     * repost or reaction. Zap receipts draw nothing yet.
     */
    fun arrival(
        kind: Int?,
        rawId: String?,
        rawAuthor: String?,
        createdAt: Double?,
        tags: List<List<String>>,
        nowSeconds: Double = System.currentTimeMillis() / 1000.0,
    ): Arrival? {
        if (kind == null || rawId == null || rawAuthor == null) return null
        // Keys are compared lowercase everywhere (follows, web, you): a relay's
        // uppercase hex must not land your own note on Global.
        val id = rawId.lowercase()
        val author = rawAuthor.lowercase()
        if (kind !in KINDS && kind !in REPOST_KINDS && kind != GlobeLive.REACTION_KIND) return null
        if (!isKey(id) || !isKey(author)) return null
        if (createdAt != null && nowSeconds - createdAt > MAX_AGE) return null
        // A reaction flies to whoever it reacts to, or not at all.
        if (kind == GlobeLive.REACTION_KIND) return GlobeLive.reaction(id, author, tags)
        // Comments on videos, articles and the like aren't conversation.
        if (kind == NIP10Thread.COMMENT_KIND && !NIP10Thread.isNoteComment(kind, tags)) return null
        // A reply flies to the person it answers, not to everyone in the thread.
        val to = repliedTo(kind, tags)
        if (to != null && to != author) return Arrival(id, author, listOf(to), sort = Sort.REPLY)
        // A reply we can't place (no pubkey slot, no p tag) doesn't fly: only a
        // note aimed at no one lands on you.
        if (isReply(kind, tags) && to == null) return null
        val targets = ArrayList<String>()
        for (tag in tags) {
            if (tag.size < 2 || tag[0] != "p") continue
            val key = tag[1].lowercase()
            if (!isKey(key) || key == author || key in targets) continue
            targets += key
            if (targets.size == MAX_TARGETS) break
        }
        // A repost with no p tag has no one to point at: it flies into you.
        val sort = when {
            kind in REPOST_KINDS -> Sort.REPOST
            isReply(kind, tags) -> Sort.REPLY
            else -> Sort.NOTE
        }
        return Arrival(id, author, targets, sort = sort)
    }

    /** [arrival] from a relay `EVENT`'s event object. */
    fun arrival(event: JsonObject, nowSeconds: Double = System.currentTimeMillis() / 1000.0): Arrival? =
        arrival(
            kind = (event["kind"] as? JsonPrimitive)?.intOrNull,
            rawId = (event["id"] as? JsonPrimitive)?.takeIf { it.isString }?.content,
            rawAuthor = (event["pubkey"] as? JsonPrimitive)?.takeIf { it.isString }?.content,
            createdAt = (event["created_at"] as? JsonPrimitive)?.doubleOrNull,
            tags = tags(event["tags"]),
            nowSeconds = nowSeconds,
        )

    /** A relay event's tags as strings; anything malformed is left out. */
    fun tags(element: JsonElement?): List<List<String>> =
        (element as? JsonArray)?.mapNotNull { tag ->
            (tag as? JsonArray)?.map { (it as? JsonPrimitive)?.takeIf { p -> p.isString }?.content ?: return@mapNotNull null }
        }.orEmpty()

    /**
     * Who a reply answers: the author of the event it replies to. NIP-10 puts it
     * in the parent `e` tag's fifth slot; a NIP-22 comment in its `e` tag's
     * fourth slot and its `p`. Without that, the first `p` tag. Null for a note
     * that isn't a reply (a quote's `e` is a mention, not a parent).
     */
    fun repliedTo(kind: Int, tags: List<List<String>>): String? {
        fun key(s: String?) = s?.lowercase()?.takeIf(::isKey)
        val firstP = tags.firstOrNull { it.size >= 2 && it[0] == "p" }?.get(1)
        if (kind == NIP10Thread.COMMENT_KIND) {
            val e = tags.firstOrNull { it.size >= 2 && it[0] == "e" }
            return key(e?.getOrNull(3)) ?: key(firstP)
        }
        if (kind !in KINDS) return null
        val parent = NIP10Thread.parentEventId(kind, tags) ?: return null
        val e = tags.firstOrNull { it.size >= 2 && it[0] == "e" && it[1] == parent }
        return key(e?.getOrNull(4)) ?: key(firstP)
    }

    /** True for a note that answers another: a comment, or a kind 1 with a parent `e` tag. */
    fun isReply(kind: Int, tags: List<List<String>>): Boolean =
        kind == NIP10Thread.COMMENT_KIND || (kind == 1 && NIP10Thread.parentEventId(kind, tags) != null)

    /** Which feed a note's author belongs to: yours and your follows' Following, your wider web's Discover, anyone else's Global. */
    fun ring(author: String, follows: Set<String>, discover: Set<String>): Ring = when (author) {
        in follows -> Ring.FOLLOWING
        in discover -> Ring.DISCOVER
        else -> Ring.GLOBAL
    }

    fun isKey(s: String): Boolean = s.length == 64 && s.all { it in '0'..'9' || it in 'a'..'f' || it in 'A'..'F' }

    class Line(
        /** The note it carries. */
        val note: String,
        val from: String,
        val to: String,
        /** Aimed at you, or at no one and so flying into you. */
        val toMe: Boolean,
        /** The feed its note came in on: where its star sets out. */
        val ring: Ring,
        val born: Double,
        /** What it carries: a reaction's star is smaller. */
        val sort: Sort,
    ) {
        /** Set when a newer line needs the room: it fades from here. */
        var retired: Double? = null
    }

    /**
     * Where a line is at a moment: its star at [head] (0 at the author, 1 at the
     * target), its faint trail behind at [trail], and the light where it lands at
     * [alpha]. [landing] runs 0 to 1 as it lands.
     */
    data class Stage(val head: Double, val trail: Double, val alpha: Double, val landing: Double)

    /**
     * Everything live on the globe. Every arrival flies on the next frame: there
     * is no queue, only the line cap. Used on one thread (the frame clock's).
     */
    class Board {
        val lines = ArrayList<Line>()
        /** Arrived since the last frame: let on, all of them, at the next. */
        private val waiting = ArrayList<Arrival>()
        private val seen = HashSet<String>()
        private val seenOrder = ArrayDeque<String>()

        val isIdle: Boolean get() = lines.isEmpty() && waiting.isEmpty()

        /** Busy enough that the globe draws at full frame rate. */
        val isBusy: Boolean get() = lines.size + waiting.size >= GlobeStorm.BUSY_LINES

        /**
         * Takes a note in; one already seen (another relay sent it too) is
         * skipped. Between two frames at most a cap's worth wait, the widest
         * feed's oldest going first, so a busy Global never pushes out a note
         * from someone you follow.
         */
        fun add(arrival: Arrival) {
            if (!seen.add(arrival.id)) return
            seenOrder.addLast(arrival.id)
            while (seenOrder.size > SEEN_CAP) seen.remove(seenOrder.removeFirst())
            waiting += arrival
            if (waiting.size > MAX_LINES) {
                val widest = waiting.maxOf { it.ring }
                waiting.removeAt(waiting.indexOfFirst { it.ring == widest })
            }
        }

        /** Lets every waiting note on and drops what has faded. Returns the notes let on. */
        fun step(now: Double, me: String): List<Arrival> {
            lines.removeAll { isGone(it, now) }
            if (waiting.isEmpty()) return emptyList()
            val released = ArrayList(waiting)
            waiting.clear()
            for (next in released) {
                // Aimed at no one: it flies into you, where your relay is.
                for (target in next.targets.ifEmpty { listOf(me) }) {
                    if (target == next.author) continue
                    lines += Line(next.id, next.author, target, target == me, next.ring, now, next.sort)
                }
            }
            retireOverCap(now)
            return released
        }

        /** Over the cap, the widest feed's oldest standing lines start their fade now: Global first. */
        private fun retireOverCap(now: Double) {
            var over = lines.count { it.retired == null } - MAX_LINES
            if (over <= 0) return
            for (ring in Ring.entries.reversed()) {
                for (line in lines) {
                    if (over <= 0) return
                    if (line.retired == null && line.ring == ring) {
                        line.retired = now
                        over--
                    }
                }
            }
        }

        /**
         * Whose pictures to show: the ends of the newest lines, up to [limit]
         * people. A storm's hundreds of lines keep their stars; only the freshest
         * get faces.
         */
        fun faceKeys(limit: Int, except: String): List<String> {
            val keys = ArrayList<String>()
            for (i in lines.indices.reversed()) {
                val line = lines[i]
                if (line.retired != null) continue
                for (key in listOf(line.from, line.to)) {
                    if (key == except || key in keys) continue
                    if (keys.size >= limit) return keys
                    keys += key
                }
            }
            return keys
        }

        fun clear() {
            lines.clear()
            waiting.clear()
        }

        companion object {
            /** Ids remembered to drop a note another relay sends again. */
            const val SEEN_CAP = 4_096
        }
    }

    fun stage(line: Line, now: Double, reduceMotion: Boolean = false): Stage {
        val age = maxOf(0.0, now - line.born)
        val head = if (reduceMotion) 1.0 else ease(minOf(1.0, age / TRAVEL))
        val landed = if (reduceMotion) age else age - TRAVEL
        val landing = if (reduceMotion) 0.0 else (landed / 1.2).coerceIn(0.0, 1.0)
        var alpha = 1.0
        if (age > TRAVEL + HOLD) alpha = 1 - minOf(1.0, (age - TRAVEL - HOLD) / FADE)
        var trail = if (landed > 0) 1 - minOf(1.0, landed / TRAIL_FADE) else 1.0
        line.retired?.let { retired ->
            val out = 1 - minOf(1.0, maxOf(0.0, now - retired) / RETIRE_FADE)
            alpha = minOf(alpha, out)
            trail = minOf(trail, out)
        }
        if (age < 0.25) alpha = minOf(alpha, age / 0.25)
        return Stage(head, minOf(trail, alpha), maxOf(0.0, alpha), landing)
    }

    /**
     * True once a line has faded out for good. Not `alpha <= 0`: a line is also
     * at 0 the instant it is let on (it fades in), and that instant can be drawn
     * twice, which dropped every star before it flew.
     */
    fun isGone(line: Line, now: Double): Boolean {
        line.retired?.let { if (now - it >= RETIRE_FADE) return true }
        return now - line.born >= TRAVEL + HOLD + FADE
    }

    /** How brightly an endpoint's face shows: in as its line sets out, out as it fades. */
    fun faceAlpha(line: Line, now: Double): Double {
        val fadeIn = ((now - line.born) / 0.8).coerceIn(0.0, 1.0)
        return minOf(fadeIn, stage(line, now).alpha)
    }

    /**
     * The biggest REQ message sent to one relay. Relays cap a message's size
     * (relay.btcforplebs.com at 128 KB) and refuse a bigger one whole: every
     * filter in it is lost. One 500-author filter is about 33.5 KB, so this fits
     * one or two; a single filter past about 890 authors goes on its own.
     */
    const val MAX_REQUEST_BYTES = 60_000

    /**
     * [filters] as REQ messages, each with its own subscription id and under
     * [maxBytes] (a single filter bigger than that goes on its own). Filters
     * keep their order; one message keeps [subId], several get `-0`, `-1`, ….
     */
    fun requests(filters: List<JsonObject>, subId: String, maxBytes: Int = MAX_REQUEST_BYTES): List<String> {
        fun text(id: String, group: List<JsonObject>) = buildJsonArray {
            add(JsonPrimitive("REQ"))
            add(JsonPrimitive(id))
            group.forEach { add(it) }
        }.toString()
        val groups = ArrayList<List<JsonObject>>()
        var current = ArrayList<JsonObject>()
        for (filter in filters) {
            val candidate = current + filter
            if (current.isNotEmpty() && text(subId, candidate).toByteArray().size > maxBytes) {
                groups += current
                current = arrayListOf(filter)
            } else {
                current = ArrayList(candidate)
            }
        }
        if (current.isNotEmpty()) groups += current
        return groups.mapIndexed { i, group -> text(if (groups.size == 1) subId else "$subId-$i", group) }
    }

    fun ease(t: Double) = t * t * (3 - 2 * t)

    /**
     * A point [t] of the way along a line from [a] to [b], lifted off the globe
     * so it reads as a flight rather than a cut through it. [facing] is toward
     * the viewer: a line bent to one side bends across the screen.
     */
    fun point(a: Vec3, b: Vec3, t: Double, facing: Vec3 = Vec3(0.0, 0.0, 1.0)): Vec3 {
        val c = control(a, b, facing)
        val u = 1 - t
        return a * (u * u) + c * (2 * u * t) + b * (t * t)
    }

    /** The bend: away from the core, or to one side when the line runs at or through the core. */
    fun control(a: Vec3, b: Vec3, facing: Vec3 = Vec3(0.0, 0.0, 1.0)): Vec3 {
        val mid = (a + b) / 2.0
        val span = (b + a * -1.0).length
        if (span <= 1e-6) return mid
        val lift = 0.32 * span
        val along = (b + a * -1.0) / span
        // Out from the core, square to the line: a line running into the core
        // has nothing square to it there, and bends sideways instead.
        val out = mid + along * -mid.dot(along)
        if (out.length > 0.25 * span) return mid + out.normalized() * lift
        var side = along.cross(facing)
        if (side.length < 1e-3) side = along.cross(Vec3(0.0, 1.0, 0.0))
        if (side.length < 1e-3) side = along.cross(Vec3(1.0, 0.0, 0.0))
        return mid + side.normalized() * lift
    }
}
