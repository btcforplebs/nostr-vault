package com.nostrvault.data.model

import kotlin.math.PI
import kotlin.math.abs
import kotlin.math.acos
import kotlin.math.cos
import kotlin.math.exp
import kotlin.math.max
import kotlin.math.min
import kotlin.math.sin
import kotlin.math.sqrt

/**
 * The pure parts of the Web of Trust globe: where each person sits, which
 * follow lists to ask for next, and the 3-hop "look deeper" chains. No layout
 * is ever iterated: a person's spot comes straight from their key, so the same
 * person sits in the same place every time the globe opens.
 *
 * Port of iOS Models/TrustMap.swift.
 */
object TrustMap {
    /**
     * Follow lists asked for per "show everyone" batch. Each list is a whole
     * follow list (~90 KB at 1,000 follows), so one batch is ~2 MB.
     */
    const val BATCH_SIZE = 20
    /** Stop "show everyone" here (~9 MB). Past it the button asks again. */
    const val MAX_BATCHED_LISTS = 100
    /** Lists tagging the author fetched from anyone for "look deeper". */
    const val DEEPER_SEEDS = 30
    /** Lists from your follows that tag one of those seeds. */
    const val DEEPER_LINKS = 12
    /** Faces drawn for 3-hop chains; the rest stay dots. */
    const val SHOWN_CHAINS = 12

    /**
     * Radius of each shell: whoever is in the middle at 0, their follows on
     * the unit sphere, and people further out on a faint outer shell.
     */
    const val RING_RADIUS = 1.0
    const val OUTER_RADIUS = 1.62
    /** The author sits between the two shells, so their threads stay short. */
    const val AUTHOR_RADIUS = 1.32
    /**
     * Outer-shell people drawn per globe. Your follows' follows run to tens of
     * thousands; past this the shell reads the same and only costs frames.
     */
    const val HAZE_CAP = 2_500
    /** The outer shell on a lite phone: still a full shell, a quarter of the dots. */
    const val HAZE_CAP_LITE = 600
    /**
     * Phones at or under this much RAM get the lite globe. A "4 GB" phone
     * reports about 3.7 GB, a "6 GB" one about 5.5 GB.
     */
    const val LITE_MEMORY_BYTES = 4L * 1024 * 1024 * 1024

    /** Lite globe: fewer haze dots, and stars drawn as points instead of shapes. */
    fun isLite(totalMemBytes: Long, lowRamDevice: Boolean): Boolean =
        lowRamDevice || totalMemBytes in 1..LITE_MEMORY_BYTES

    /**
     * A person's fixed spot on the globe, from their key alone. Longitude and
     * height come from separate hex digits; taking height straight (not as an
     * angle) spreads people evenly over the sphere instead of bunching them at
     * the poles.
     */
    fun direction(pubkey: String): Vec3 {
        val longitude = fraction(pubkey, 0) * 2 * PI
        val z = fraction(pubkey, 8) * 2 - 1
        val r = sqrt(1 - z * z)
        return Vec3(r * cos(longitude), r * sin(longitude), z)
    }

    /**
     * Up to [cap] of [candidates], picked by key so the same people show every
     * time: a growing set only swaps people at the margin.
     */
    fun haze(candidates: Set<String>, cap: Int = HAZE_CAP): List<String> {
        if (candidates.size <= cap) return candidates.sorted()
        return candidates
            .map { fraction(it, 16) to it }
            .sortedWith(compareBy({ it.first }, { it.second }))
            .take(cap)
            .map { it.second }
    }

    private fun fraction(pubkey: String, offset: Int): Double {
        val hex = pubkey.drop(offset).take(8)
        if (hex.length == 8 && hex.all { it in '0'..'9' || it in 'a'..'f' || it in 'A'..'F' }) {
            return hex.toLong(16) / 4_294_967_296.0
        }
        // Not hex (only in tests or a malformed tag): FNV-1a, still stable.
        var hash = 2_166_136_261u
        for (byte in pubkey.encodeToByteArray().drop(offset)) {
            hash = (hash xor byte.toUByte().toUInt()) * 16_777_619u
        }
        return hash.toDouble() / 4_294_967_296.0
    }

    /**
     * Up to [count] of [sorted], evenly spaced through it. Keys sort in
     * longitude order (that is the key's leading digits), so taking the first
     * few would bunch every face on one arc; spacing them spreads faces around.
     */
    fun spread(sorted: List<String>, count: Int): List<String> {
        if (sorted.size <= count || count <= 0) return sorted
        return (0 until count).map { sorted[it * sorted.size / count] }
    }

    /** Ring people considered for faces when the core is the author (the WOT tab). */
    const val FACE_CANDIDATES = 48
    /** Ring faces drawn when the core is the author; the rest stay dots. */
    const val RING_FACES = 16

    /**
     * Who might get a face when the core is the author. There are no bridges
     * there, so without these the only face is the core and "tap anyone" is
     * false. The people you interact with most ([engagement]) come first,
     * busiest first; then a spread of the rest, the same people every time.
     */
    fun faceCandidates(
        ring: List<String>,
        engagement: Map<String, Int> = emptyMap(),
        count: Int = FACE_CANDIDATES,
    ): List<String> {
        val top = ring.filter { (engagement[it] ?: 0) > 0 }
            .sortedWith(compareByDescending<String> { engagement[it] ?: 0 }.thenBy { it })
            .take(count)
        val taken = top.toSet()
        return top + spread(ring.filter { it !in taken }.sorted(), count - top.size)
    }

    /**
     * Up to [count] of [candidates], in candidate order: only people whose
     * picture has actually loaded ([renders]), so the globe shows faces,
     * never initials or broken pictures. The rest stay dots.
     */
    fun pickFaces(candidates: List<String>, renders: (String) -> Boolean, count: Int = RING_FACES): List<String> {
        if (count <= 0) return emptyList()
        return candidates.filter(renders).take(count)
    }

    /** Kinds that count as interacting: notes (replies, mentions), reposts, reactions, zap receipts. */
    val ENGAGEMENT_KINDS = listOf(1, 6, 7, 9735)

    /** The parts of an event [engagementScores] reads. */
    data class Interaction(val pubkey: String, val kind: Int, val tags: List<List<String>>)

    /**
     * How much you and each person interact, from your own events ([mine]:
     * the people they tag) and events aimed at you ([toMe]: who sent them).
     * Your own count double, a zap triples. You never score yourself.
     */
    fun engagementScores(mine: List<Interaction>, toMe: List<Interaction>, me: String): Map<String, Int> {
        fun weight(kind: Int) = if (kind == 9735) 3 else 1
        val scores = HashMap<String, Int>()
        for (event in mine) {
            if (event.pubkey != me) continue
            // A reply tags the whole thread; the last p is who you answered.
            val target = event.tags.lastOrNull { it.size > 1 && it[0] == "p" }?.get(1) ?: continue
            scores[target] = (scores[target] ?: 0) + 2 * weight(event.kind)
        }
        for (event in toMe) {
            if (event.tags.none { it.size > 1 && it[0] == "p" && it[1] == me }) continue
            val sender = if (event.kind == 9735) {
                event.tags.firstOrNull { it.size > 1 && it[0] == "P" }?.get(1)
            } else {
                event.pubkey
            } ?: continue
            scores[sender] = (scores[sender] ?: 0) + weight(event.kind)
        }
        scores.remove(me)
        return scores
    }

    /** How close a search hit is to you: the tag on its row, and its rank. */
    enum class Tier { FOLLOW, WEB, OTHER }

    data class PersonHit(val pubkey: String, val tier: Tier)

    /**
     * The WOT tab's search over profiles already cached: a case-insensitive
     * "contains" on display name, name and NIP-05. People you follow come
     * first, then your wider web, then everyone else; within that a name that
     * starts with the query beats one that only contains it, then the shorter
     * name wins, since it's the closer match. Instant, so it runs every keystroke.
     */
    fun searchPeople(
        query: String,
        people: Collection<FeedProfile>,
        follows: Set<String>,
        web: Set<String>,
        limit: Int = 8,
    ): List<PersonHit> {
        val q = query.trim().lowercase()
        if (q.isEmpty() || limit <= 0) return emptyList()
        class Ranked(val hit: PersonHit, val prefix: Boolean, val length: Int)
        val ranked = ArrayList<Ranked>()
        for (person in people) {
            val fields = listOfNotNull(person.displayName, person.name, person.nip05)
                .map { it.trim().lowercase() }
                .filter { it.isNotEmpty() }
            if (fields.none { it.contains(q) }) continue
            val tier = when (person.pubkey) {
                in follows -> Tier.FOLLOW
                in web -> Tier.WEB
                else -> Tier.OTHER
            }
            val name = person.displayName?.trim()?.takeIf { it.isNotEmpty() }
                ?: person.name?.trim()?.takeIf { it.isNotEmpty() }
                ?: person.nip05.orEmpty()
            ranked += Ranked(PersonHit(person.pubkey, tier), fields.any { it.startsWith(q) }, name.length)
        }
        return ranked
            .sortedWith(compareBy({ it.hit.tier }, { !it.prefix }, { it.length }, { it.hit.pubkey }))
            .take(limit)
            .map { it.hit }
    }

    /**
     * The key a pasted npub or 64-hex names, or null. [decodeNpub] is the app's
     * NIP-19 decoder, passed in so this stays pure. A "nostr:" prefix is fine.
     */
    fun pastedKey(query: String, decodeNpub: (String) -> String?): String? {
        val text = query.trim().removePrefix("nostr:")
        if (text.length == 64 && text.all { it in '0'..'9' || it in 'a'..'f' || it in 'A'..'F' }) return text.lowercase()
        if (text.startsWith("npub1", ignoreCase = true)) {
            return runCatching { decodeNpub(text.lowercase()) }.getOrNull()?.takeIf { it.length == 64 }
        }
        return null
    }

    /**
     * The next "show everyone" filters: follows whose lists haven't come back
     * yet, tagging the author, chunked for relays that cap a request's size.
     * Empty once every follow has been asked about.
     */
    fun nextBatch(
        author: String,
        follows: List<String>,
        seen: Set<String>,
        chunkSize: Int = 1000,
    ): List<FollowListFilter> =
        follows.filter { it != author && it !in seen }.chunked(chunkSize).map {
            FollowListFilter(authors = it, tagged = listOf(author), limit = BATCH_SIZE)
        }

    /**
     * The p-tags of the newest follow list [owner] signed: who they follow.
     * Lists from anyone else are ignored. Null when no list came back.
     */
    fun follows(owner: String, lists: List<ContactList>): List<String>? {
        val best = lists.filter { it.kind == 3 && it.pubkey == owner }
            .fold(null as ContactList?) { newest, list -> if (newest != null && newest.createdAt >= list.createdAt) newest else list }
            ?: return null
        val seen = HashSet<String>()
        return best.tags.mapNotNull { tag ->
            if (tag.size >= 2 && tag[0] == "p" && tag[1].length == 64 && tag[1] != owner && seen.add(tag[1])) tag[1] else null
        }
    }

    /** One 3-hop route: you follow [bridge], who follows [via], who follows the author. */
    data class Chain(val bridge: String, val via: String)

    /** Step 1 of "look deeper": anyone's follow list that tags the author. */
    fun deeperSeedFilter(author: String) = FollowListFilter(authors = null, tagged = listOf(author), limit = DEEPER_SEEDS)

    /**
     * Who the seed lists say follows the author, minus you, your follows and
     * the author: the possible middle steps. People already in your trust
     * graph come first, since your follows most likely follow them.
     */
    fun deeperVia(
        author: String,
        me: String,
        follows: Set<String>,
        trustGraph: Set<String>,
        seeds: List<ContactList>,
    ): List<String> {
        val candidates = TrustPath.allBridges(author, me, seeds.mapTo(HashSet()) { it.pubkey }, seeds)
            .filter { it !in follows }
        if (trustGraph.isEmpty()) return candidates
        return candidates.filter { it in trustGraph } + candidates.filter { it !in trustGraph }
    }

    /** Step 2: lists from your follows that tag any of the middle steps. */
    fun deeperLinkFilters(follows: List<String>, via: List<String>, chunkSize: Int = 1000): List<FollowListFilter> {
        if (via.isEmpty()) return emptyList()
        return follows.chunked(chunkSize).map { FollowListFilter(authors = it, tagged = via, limit = DEEPER_LINKS) }
    }

    /**
     * Every route the link lists show, sorted by middle step then bridge. Only
     * each follow's newest list counts, as in [TrustPath.resolve].
     */
    fun chains(me: String, follows: Set<String>, via: List<String>, links: List<ContactList>): List<Chain> {
        val viaSet = via.toSet()
        val routes = HashSet<Chain>()
        val bridges = links.map { it.pubkey }.distinct().filter { it in follows && it != me }.sorted()
        for (bridge in bridges) {
            for (target in follows(bridge, links).orEmpty()) {
                if (target in viaSet) routes += Chain(bridge, target)
            }
        }
        return routes.sortedWith(compareBy({ it.via }, { it.bridge }))
    }
}

/** A point or direction in globe space: x right, y up, z toward the viewer. */
data class Vec3(val x: Double, val y: Double, val z: Double) {
    operator fun plus(o: Vec3) = Vec3(x + o.x, y + o.y, z + o.z)
    operator fun times(k: Double) = Vec3(x * k, y * k, z * k)
    operator fun div(k: Double) = Vec3(x / k, y / k, z / k)
    fun dot(o: Vec3) = x * o.x + y * o.y + z * o.z
    fun cross(o: Vec3) = Vec3(y * o.z - z * o.y, z * o.x - x * o.z, x * o.y - y * o.x)
    val length: Double get() = sqrt(dot(this))
    fun normalized(): Vec3 = this / length
    /** Compared with `==`, so −0.0 counts as still (a data class's equals would not). */
    val isZero: Boolean get() = x == 0.0 && y == 0.0 && z == 0.0

    companion object {
        val ZERO = Vec3(0.0, 0.0, 0.0)
    }
}

/**
 * A rotation, as iOS's `simd_quatd`: [w] real, ([x], [y], [z]) imaginary.
 * `a * b` turns by `b` first, then `a`.
 */
data class Quat(val w: Double, val x: Double, val y: Double, val z: Double) {
    operator fun times(q: Quat) = Quat(
        w * q.w - x * q.x - y * q.y - z * q.z,
        w * q.x + x * q.w + y * q.z - z * q.y,
        w * q.y - x * q.z + y * q.w + z * q.x,
        w * q.z + x * q.y - y * q.x + z * q.w,
    )

    fun dot(q: Quat) = w * q.w + x * q.x + y * q.y + z * q.z

    fun normalized(): Quat {
        val n = sqrt(dot(this))
        return Quat(w / n, x / n, y / n, z / n)
    }

    /** Row-major 3×3 rotation matrix, worked out once per frame. */
    fun matrix(): DoubleArray = doubleArrayOf(
        1 - 2 * (y * y + z * z), 2 * (x * y - w * z), 2 * (x * z + w * y),
        2 * (x * y + w * z), 1 - 2 * (x * x + z * z), 2 * (y * z - w * x),
        2 * (x * z - w * y), 2 * (y * z + w * x), 1 - 2 * (x * x + y * y),
    )

    companion object {
        val IDENTITY = Quat(1.0, 0.0, 0.0, 0.0)

        fun angle(radians: Double, axis: Vec3): Quat {
            val a = axis.normalized()
            val s = sin(radians / 2)
            return Quat(cos(radians / 2), a.x * s, a.y * s, a.z * s)
        }

        /** The shortest turn taking unit vector [from] to unit vector [to]. */
        fun between(from: Vec3, to: Vec3): Quat {
            val d = from.dot(to)
            if (d < -0.999999) {
                // Opposite: any axis at right angles will do.
                var axis = Vec3(1.0, 0.0, 0.0).cross(from)
                if (axis.length < 1e-6) axis = Vec3(0.0, 1.0, 0.0).cross(from)
                return angle(PI, axis)
            }
            val c = from.cross(to)
            return Quat(1 + d, c.x, c.y, c.z).normalized()
        }

        /** Spherical blend from [a] to [b] by [t], the short way round. */
        fun slerp(a: Quat, b: Quat, t: Double): Quat {
            var d = a.dot(b)
            val end = if (d < 0) { d = -d; Quat(-b.w, -b.x, -b.y, -b.z) } else b
            if (d > 0.9995) {
                return Quat(
                    a.w + (end.w - a.w) * t, a.x + (end.x - a.x) * t,
                    a.y + (end.y - a.y) * t, a.z + (end.z - a.z) * t,
                ).normalized()
            }
            val theta = acos(d)
            val s = sin(theta)
            val ka = sin((1 - t) * theta) / s
            val kb = sin(t * theta) / s
            return Quat(
                a.w * ka + end.w * kb, a.x * ka + end.x * kb,
                a.y * ka + end.y * kb, a.z * ka + end.z * kb,
            )
        }
    }
}

/**
 * The globe's camera and how it moves. Every step is scaled by the real time
 * since the last frame, so it spins, glides and settles the same at 60 Hz and
 * 120 Hz. Times are in seconds on the frame clock.
 */
class GlobeCamera {
    var orientation = Quat.IDENTITY
    /** Angular velocity after a flick, radians a second. */
    var spin = Vec3.ZERO
    var zoom = 1.0
    var zoomTarget = 1.0
    /** Where a fly-to is turning; null when not flying. */
    var flyTarget: Quat? = null
    var dragging = false
    /** Frame-clock time of the last touch. */
    var lastTouch = 0.0

    companion object {
        val ZOOM_RANGE = 0.8..2.4
        /** Idle this long and the globe starts drifting, so it reads as alive. */
        const val DRIFT_AFTER = 3.0
        /** Idle this long and it stops: the frame clock can sleep. */
        const val SLEEP_AFTER = 20.0
        const val DRIFT_SPEED = 0.05
        /** How fast a flick dies away, per second. */
        const val SPIN_DECAY = 1.6
        /** A frame slower than this counts as this long, so a hitch can't fling it. */
        const val MAX_STEP = 1.0 / 20

        private val Y_AXIS = Vec3(0.0, 1.0, 0.0)
        private val X_AXIS = Vec3(1.0, 0.0, 0.0)

        /**
         * The turn that brings [direction] to the front, a little up and right
         * of the middle, so whoever it is never hides behind the core.
         */
        fun facing(direction: Vec3): Quat =
            Quat.between(direction.normalized(), Vec3(0.42, 0.30, 1.0).normalized())
    }

    fun touch(now: Double) { lastTouch = now }

    /** One finger moved by [dx], [dy] dp: turn under it. */
    fun drag(dx: Double, dy: Double, now: Double) {
        val k = 0.009
        val turn = Quat.angle(dx * k, Y_AXIS) * Quat.angle(dy * k, X_AXIS)
        orientation = (turn * orientation).normalized()
        flyTarget = null
        spin = Vec3.ZERO
        touch(now)
    }

    /** Let go at [vx], [vy] dp a second: keep turning that way. */
    fun flick(vx: Double, vy: Double, now: Double, reduceMotion: Boolean) {
        val k = 0.006
        spin = if (reduceMotion) Vec3.ZERO else Vec3(vy * k, vx * k, 0.0)
        touch(now)
    }

    fun fly(target: Quat, now: Double) {
        flyTarget = target
        spin = Vec3.ZERO
        zoomTarget = 1.0
        touch(now)
    }

    fun zoomBy(factor: Double, now: Double) {
        zoomTarget = (zoomTarget * factor).coerceIn(ZOOM_RANGE)
        touch(now)
    }

    fun step(dt: Double, now: Double, reduceMotion: Boolean) {
        @Suppress("NAME_SHADOWING")
        val dt = min(MAX_STEP, max(0.0, dt))
        val target = flyTarget
        if (target != null) {
            orientation = if (reduceMotion) target else Quat.slerp(orientation, target, 1 - exp(-dt * 5))
            if (reduceMotion || abs(orientation.dot(target)) > 0.99999) {
                orientation = target
                flyTarget = null
            }
        } else if (!dragging && !reduceMotion) {
            val speed = spin.length
            if (speed > 0.0005) {
                // The exact turn while the spin decays over this step, not
                // speed × dt: summed per frame, that drifts with the frame rate.
                val decay = exp(-dt * SPIN_DECAY)
                val angle = speed * (1 - decay) / SPIN_DECAY
                orientation = (Quat.angle(angle, spin / speed) * orientation).normalized()
                spin = spin * decay
            } else {
                spin = Vec3.ZERO
            }
            val idle = now - lastTouch
            if (idle > DRIFT_AFTER && idle < SLEEP_AFTER) {
                orientation = (Quat.angle(DRIFT_SPEED * dt, Y_AXIS) * orientation).normalized()
            }
        }
        if (reduceMotion || abs(zoomTarget - zoom) < 0.0005) {
            zoom = zoomTarget
        } else {
            zoom += (zoomTarget - zoom) * (1 - exp(-dt * 7))
        }
    }

    /**
     * Something on screen is still moving, or will start drifting soon: keep
     * the frame clock running. False is the cue to let it sleep.
     */
    fun wantsFrames(now: Double, reduceMotion: Boolean): Boolean {
        if (dragging || flyTarget != null || !spin.isZero || zoom != zoomTarget) return true
        return !reduceMotion && now - lastTouch < SLEEP_AFTER
    }
}
