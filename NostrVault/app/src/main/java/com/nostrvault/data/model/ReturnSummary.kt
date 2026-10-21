package com.nostrvault.data.model

/**
 * What came in while the app was away, as the one bottom pill shows it
 * ("5 mentions · 2 zaps · 1 DM"; iOS `ReturnSummary`). Coming back used to put
 * up a top pill and a sound for nearly every arrival the relay caught up on,
 * one after another; on that first load back they are gathered here instead
 * (Logen, 2026-10-14).
 */
class ReturnSummary {
    /** What the pill counts, in the order it lists them. */
    enum class Category(private val one: String, private val many: String) {
        MENTION("mention", "mentions"),
        REPLY("reply", "replies"),
        ZAP("zap", "zaps"),
        DM("DM", "DMs"),
        REACTION("reaction", "reactions"),
        REPOST("repost", "reposts"),
        FOLLOWER("new follower", "new followers"),
        OTHER("update", "updates");

        fun label(count: Int) = if (count == 1) one else many

        companion object {
            /** The marker type an arrival pill was raised for (see LocalNotificationService.handle). */
            fun of(type: String): Category = when (type) {
                // A quote of your note is a mention of you (the Mentions switch governs it).
                "mention", "quote" -> MENTION
                "reply" -> REPLY
                "zap" -> ZAP
                "dm", "giftwrap" -> DM
                "reaction", "like" -> REACTION
                "repost" -> REPOST
                "follow", "followers" -> FOLLOWER
                else -> OTHER
            }
        }
    }

    private val keys = HashMap<Category, MutableSet<String>>()

    /**
     * Counts one arrival once, however many times it is announced (a relay
     * marker and the system alert for the same event). False when [key] was
     * already counted.
     */
    fun add(type: String, key: String): Boolean = keys.getOrPut(Category.of(type)) { HashSet() }.add(key)

    val isEmpty: Boolean get() = total == 0
    val total: Int get() = keys.values.sumOf { it.size }
    fun count(category: Category): Int = keys[category]?.size ?: 0

    /** "5 mentions · 2 zaps · 1 DM"; past [MAX_LISTED] kinds, "… · +4 more". */
    val text: String
        get() {
            val present = Category.entries.filter { count(it) > 0 }
            val parts = present.take(MAX_LISTED).map { "${count(it)} ${it.label(count(it))}" }.toMutableList()
            val rest = present.drop(MAX_LISTED).sumOf { count(it) }
            if (rest > 0) parts += "+$rest more"
            return parts.joinToString(" · ")
        }

    /** The same, for TalkBack: commas, not dots. */
    val spokenText: String
        get() = Category.entries.filter { count(it) > 0 }.joinToString(", ") { "${count(it)} ${it.label(count(it))}" }

    companion object {
        /** Past this many kinds the rest fold into "+N more", so the pill stays one line on a phone. */
        const val MAX_LISTED = 3
    }
}

/**
 * When arrivals after a return are gathered into the bottom pill, and how long
 * that pill stays (iOS `ReturnWindow`). Opens as the app comes back from the
 * background; arrivals inside it make no top pill and no sound of their own.
 * Times are epoch milliseconds.
 *
 * - Nothing arrives within [WAIT_FOR_FIRST_MS]: it closes, and anything later
 *   is live and gets the ordinary top pill.
 * - Each arrival keeps it open [SETTLE_MS] longer, since the relay's catch-up
 *   and the DM sync land in bursts over several seconds, but never past
 *   [MAXIMUM_MS] after the return: by then it is live traffic again.
 * - An event created before the return came in while you were away, however
 *   late the relay hands it over, so it is gathered too, up to
 *   [LATE_HORIZON_MS] after the return. It brings the pill back if it had gone,
 *   but never a second sound.
 * - The pill stays at least [MINIMUM_SHOW_MS] after an arrival brings it up, so
 *   one arriving just before the close is still readable.
 */
class ReturnWindow(val returnedAt: Long) {
    var firstArrival: Long? = null
        private set
    var lastArrival: Long? = null
        private set
    /** The last arrival gathered only because it was older than the return. */
    var lastLateArrival: Long? = null
        private set

    /** Until when any arrival is gathered rather than shown as a top pill. */
    val gathersUntil: Long
        get() {
            val last = lastArrival ?: return returnedAt + WAIT_FOR_FIRST_MS
            return minOf(returnedAt + MAXIMUM_MS, last + SETTLE_MS)
        }

    /** Until when the bottom pill shows. Null while nothing has arrived: no pill. */
    val showsUntil: Long?
        get() {
            val first = firstArrival ?: return null
            var until = maxOf(gathersUntil, first + MINIMUM_SHOW_MS)
            lastLateArrival?.let { until = maxOf(until, it + MINIMUM_SHOW_MS) }
            return until
        }

    fun gathers(now: Long): Boolean = now < gathersUntil

    /**
     * Whether an arrival at [now] for an event created at [createdAt] is
     * gathered, and records it if so. [createdAt] null (a DM, whose gift wrap
     * carries a made-up time) is judged by the time window alone.
     */
    fun arrive(now: Long, createdAt: Long? = null): Boolean {
        if (gathers(now)) {
            if (firstArrival == null) firstArrival = now
            lastArrival = now
            return true
        }
        if (createdAt == null || createdAt >= returnedAt || now >= returnedAt + LATE_HORIZON_MS) return false
        if (firstArrival == null) firstArrival = now
        lastLateArrival = now
        return true
    }

    companion object {
        const val WAIT_FOR_FIRST_MS = 12_000L
        const val SETTLE_MS = 6_000L
        const val MAXIMUM_MS = 30_000L
        const val MINIMUM_SHOW_MS = 6_000L
        const val LATE_HORIZON_MS = 5 * 60_000L
    }
}
