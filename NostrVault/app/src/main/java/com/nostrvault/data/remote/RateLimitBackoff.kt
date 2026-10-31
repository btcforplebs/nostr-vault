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

    private class Hold(val untilMs: Long, val strikes: Int, val refusals: Int = 0)
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
        holds[host] = Hold(until, old?.strikes ?: 0, refusals)
        return until - nowMs
    }

    /** Ms until [url]'s host may be dialled again; 0 when it isn't held. */
    @Synchronized
    fun remainingMs(url: String, nowMs: Long = System.currentTimeMillis()): Long =
        ((holds[hostOf(url)]?.untilMs ?: 0L) - nowMs).coerceAtLeast(0L)

    /** A connection to [url] stayed up: its host starts over. */
    @Synchronized
    fun recovered(url: String) {
        holds.remove(hostOf(url))
    }

    @Synchronized
    internal fun clearForTest() = holds.clear()
}

/** relay.damus.io, which bans busy IPs: asked last, and only when others didn't answer. */
fun isDamus(url: String): Boolean = RateLimitBackoff.hostOf(url) == "relay.damus.io"
