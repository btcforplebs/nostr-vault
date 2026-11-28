package com.nostrvault.data.remote

/**
 * Hosts that answered a WebSocket upgrade with 429, and how long every
 * socket to them waits before dialling again. Shared by all clients, so the
 * DM socket, the lookup pool and the metadata pool all stop at once.
 *
 * relay.damus.io bans, and publicly lists, an IP that sends it too many
 * requests in a day. A 429 used to put one socket on a 2-minute retry
 * forever (about 720 redials a day from the DM socket alone). Now the first
 * 429 holds the host for an hour, each further one doubles it up to 12
 * hours, and a connection that stays up clears it. A refused upgrade
 * ([refused]) holds the host on a short ladder the same way.
 */
object RateLimitBackoff {
    internal const val FIRST_HOLD_MS = 60 * 60 * 1000L
    internal const val MAX_HOLD_MS = 12 * 60 * 60 * 1000L

    /**
     * Holds for a host that refused the WebSocket upgrade (5xx, Cloudflare
     * 52x/530, 404, a plain 200 page). Each client used to redial it on its
     * own backoff, so a dead relay was dialled every few seconds by whichever
     * feature asked next (Moto: sendit.nosflare.com 26 times in 6.5 min).
     */
    internal val REFUSAL_HOLDS_MS = longArrayOf(30_000L, 2 * 60_000L, 10 * 60_000L)

    /** Refusals this long after the last hold ended start the ladder over. */
    internal const val REFUSAL_FORGET_MS = 30 * 60_000L

    /** [failed]: the hold's end was set by a refused upgrade, a failed connect, not by a 429. */
    private class Hold(val untilMs: Long, val strikes: Int, val refusals: Int = 0, val failed: Boolean = false)
    private val holds = HashMap<String, Hold>()

    fun hostOf(url: String): String =
        url.trim().substringAfter("://").substringBefore('/').substringBefore(':').lowercase()

    /** Record a 429 from [url]'s host; -> how long it is held, in ms. */
    @Synchronized
    fun limited(url: String, nowMs: Long = System.currentTimeMillis()): Long {
        val host = hostOf(url)
        val strikes = (holds[host]?.strikes ?: 0) + 1
        val hold = (FIRST_HOLD_MS shl (strikes - 1).coerceAtMost(4)).coerceAtMost(MAX_HOLD_MS)
        holds[host] = Hold(nowMs + hold, strikes, holds[host]?.refusals ?: 0)
        return hold
    }

    /**
     * Record a refused upgrade (any HTTP answer but 101 and 429) from [url]'s
     * host; -> how long it is held, in ms. Never shortens a 429 hold. Local
     * and LAN hosts are not held: one path there (/inbox) refusing says
     * nothing about the others.
     */
    @Synchronized
    fun refused(url: String, nowMs: Long = System.currentTimeMillis()): Long {
        if (WebSocketClient.isLocalOrLanHost(url)) return 0L
        val host = hostOf(url)
        val old = holds[host]
        val fresh = old == null || nowMs - old.untilMs > REFUSAL_FORGET_MS
        val refusals = (if (fresh) 0 else old!!.refusals) + 1
        val hold = REFUSAL_HOLDS_MS[(refusals - 1).coerceAtMost(REFUSAL_HOLDS_MS.size - 1)]
        val until = maxOf(nowMs + hold, old?.untilMs ?: 0L)
        val failed = nowMs + hold >= (old?.untilMs ?: 0L) || old?.failed == true
        holds[host] = Hold(until, old?.strikes ?: 0, refusals, failed)
        return until - nowMs
    }

    /**
     * Holds for a host the device could not reach at all (no route, DNS, a
     * connect timeout). Every client to that host shares one ladder, doubling
     * from [UNREACHABLE_FIRST_HOLD_MS] up to [UNREACHABLE_MAX_FG_MS] on screen
     * and [UNREACHABLE_MAX_BG_MS] in the background. With the network down,
     * each client redialled on its own backoff and the app started about a
     * connect a second in the background (launch/background perf review
     * 2026-11-28, finding 1). The cap is read on each check, so coming back
     * on screen cuts a long background hold to the on-screen cap at once.
     */
    internal const val UNREACHABLE_FIRST_HOLD_MS = 5_000L
    internal const val UNREACHABLE_MAX_FG_MS = 2 * 60_000L
    internal const val UNREACHABLE_MAX_BG_MS = 10 * 60_000L

    /** A failure this long after the last one starts the ladder over. */
    internal const val UNREACHABLE_FORGET_MS = 30 * 60_000L

    /** [down]: the socket failed, not a timeout ([WebSocketClient.downAtConnect]). */
    private class Unreachable(val failedAtMs: Long, val strikes: Int, val down: Boolean)
    private val unreachable = HashMap<String, Unreachable>()

    private fun unreachableUntil(u: Unreachable): Long {
        val cap = if (AppOnScreen.onScreen) UNREACHABLE_MAX_FG_MS else UNREACHABLE_MAX_BG_MS
        val hold = (UNREACHABLE_FIRST_HOLD_MS shl (u.strikes - 1).coerceIn(0, 16)).coerceAtMost(cap)
        return u.failedAtMs + hold
    }

    /**
     * Record a dial to [url] that never reached the relay; -> how long its
     * host is held, in ms. [down] is false for a timeout. Local and LAN hosts
     * are not held: this device's relay restarting says nothing about the
     * network.
     */
    @Synchronized
    fun unreachable(url: String, down: Boolean, nowMs: Long = System.currentTimeMillis()): Long {
        if (WebSocketClient.isLocalOrLanHost(url)) return 0L
        val host = hostOf(url)
        val old = unreachable[host]
        val strikes = if (old == null || nowMs - old.failedAtMs > UNREACHABLE_FORGET_MS) 1 else old.strikes + 1
        val entry = Unreachable(nowMs, strikes, down)
        unreachable[host] = entry
        return unreachableUntil(entry) - nowMs
    }

    /** A socket to [url] opened: the host is reachable again. Refusal and 429 holds stay. */
    @Synchronized
    fun reached(url: String) {
        unreachable.remove(hostOf(url))
    }

    /** Ms until [url]'s host may be dialled again; 0 when it isn't held. */
    @Synchronized
    fun remainingMs(url: String, nowMs: Long = System.currentTimeMillis()): Long {
        val host = hostOf(url)
        val until = maxOf(holds[host]?.untilMs ?: 0L, unreachable[host]?.let(::unreachableUntil) ?: 0L)
        return (until - nowMs).coerceAtLeast(0L)
    }

    /**
     * Whether [url]'s host is held now because it refused the upgrade (a failed connect), not for a 429. The follow
     * list's count leaves such a relay out, as it left it out on the ask that started the hold (FollowListKnown).
     */
    @Synchronized
    fun heldForFailure(url: String, nowMs: Long = System.currentTimeMillis()): Boolean {
        val host = hostOf(url)
        val down = unreachable[host]?.takeIf { it.down && unreachableUntil(it) > nowMs } != null
        val hold = holds[host] ?: return down
        return down || (hold.failed && hold.untilMs > nowMs)
    }

    /** A connection to [url] stayed up: its host starts over. */
    @Synchronized
    fun recovered(url: String) {
        holds.remove(hostOf(url))
        unreachable.remove(hostOf(url))
    }

    @Synchronized
    internal fun clearForTest() {
        holds.clear()
        unreachable.clear()
    }
}

/** relay.damus.io, which bans busy IPs: asked last, and only when others didn't answer. */
fun isDamus(url: String): Boolean = RateLimitBackoff.hostOf(url) == "relay.damus.io"
