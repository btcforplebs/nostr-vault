package com.nostrvault.service

import com.nostrvault.data.remote.WebSocketClient.ConnectionState

/**
 * Each feed relay's own socket state, for the feed dashboard rows and the dot
 * on the feed button (iOS #281). The feed's overall status only says whether
 * notes arrived: it read "Live" and showed every relay as connected while some
 * were down.
 */
object FeedRelayHealth {
    /** Key a relay URL the same way however it was typed (case, trailing slash). */
    fun key(url: String): String = url.trim().lowercase().trimEnd('/')

    /**
     * Configured feed relays the feed is connected to, out of those it is
     * using. A relay the feed has no socket for (paused, or a feed served by
     * another service) counts toward neither.
     */
    fun health(configured: List<String>, states: Map<String, ConnectionState>): Pair<Int, Int> {
        val used = configured.map(::key).distinct().mapNotNull { states[it] }
        return used.count { it == ConnectionState.CONNECTED } to used.size
    }

    /**
     * The feed button's dot. Grey while the feed is disconnected or paused.
     * Before any notes show it follows the load (orange, or red for a fault).
     * Once the feed is live or shows notes it reports the relays: green all
     * up, yellow some down, red none up.
     */
    fun dotColor(baseColor: String, hasNotes: Boolean, connected: Int, total: Int): String = when {
        baseColor == "gray" -> "gray"
        baseColor != "green" && !hasNotes -> if (baseColor == "red") "red" else "orange"
        total > 0 && connected == 0 -> "red"
        connected < total -> "yellow"
        else -> "green"
    }

    /** A dashboard row's label; null state means the feed is not using that relay. */
    fun label(state: ConnectionState?): String = when (state) {
        ConnectionState.CONNECTED -> "Connected"
        ConnectionState.CONNECTING, ConnectionState.RECONNECTING -> "Connecting"
        ConnectionState.DISCONNECTED -> "Offline"
        null -> "Idle"
    }
}
