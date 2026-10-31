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
 * hours, and a connection that stays up clears it.
 */
object RateLimitBackoff {
    internal const val FIRST_HOLD_MS = 60 * 60 * 1000L
    internal const val MAX_HOLD_MS = 12 * 60 * 60 * 1000L

    private class Hold(val untilMs: Long, val strikes: Int)
    private val holds = HashMap<String, Hold>()

    fun hostOf(url: String): String =
        url.trim().substringAfter("://").substringBefore('/').substringBefore(':').lowercase()

    /** Record a 429 from [url]'s host; -> how long it is held, in ms. */
    @Synchronized
    fun limited(url: String, nowMs: Long = System.currentTimeMillis()): Long {
        val host = hostOf(url)
        val strikes = (holds[host]?.strikes ?: 0) + 1
        val hold = (FIRST_HOLD_MS shl (strikes - 1).coerceAtMost(4)).coerceAtMost(MAX_HOLD_MS)
        holds[host] = Hold(nowMs + hold, strikes)
        return hold
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
