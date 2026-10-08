package com.nostrvault.service

import com.nostrvault.data.remote.WebSocketClient.ConnectionState
import org.junit.Assert.assertEquals
import org.junit.Test

/** Feed dashboard rows and the feed dot follow each relay's own socket (iOS #281). */
class FeedRelayHealthTest {
    private val relays = listOf("wss://a.example/", "wss://B.example", "wss://c.example")

    private fun states(vararg pairs: Pair<String, ConnectionState>) =
        pairs.associate { FeedRelayHealth.key(it.first) to it.second }

    @Test
    fun keyIgnoresCaseAndTrailingSlash() {
        assertEquals(FeedRelayHealth.key("wss://b.example"), FeedRelayHealth.key(" wss://B.example/ "))
    }

    @Test
    fun healthCountsOnlyRelaysTheFeedUses() {
        val s = states(
            "wss://a.example" to ConnectionState.CONNECTED,
            "wss://b.example/" to ConnectionState.RECONNECTING,
            "wss://outbox.example" to ConnectionState.CONNECTED, // not configured
        )
        assertEquals(1 to 2, FeedRelayHealth.health(relays, s))
    }

    @Test
    fun dotFollowsRelaysOnceNotesShow() {
        assertEquals("green", FeedRelayHealth.dotColor("green", hasNotes = true, connected = 3, total = 3))
        assertEquals("yellow", FeedRelayHealth.dotColor("green", hasNotes = true, connected = 2, total = 3))
        assertEquals("red", FeedRelayHealth.dotColor("green", hasNotes = true, connected = 0, total = 3))
        // Status still loading but notes on screen: report the relays.
        assertEquals("yellow", FeedRelayHealth.dotColor("yellow", hasNotes = true, connected = 1, total = 3))
        // Nothing configured in use: no relay to call down.
        assertEquals("green", FeedRelayHealth.dotColor("green", hasNotes = true, connected = 0, total = 0))
    }

    @Test
    fun dotFollowsTheLoadBeforeNotes() {
        assertEquals("orange", FeedRelayHealth.dotColor("yellow", hasNotes = false, connected = 0, total = 3))
        assertEquals("red", FeedRelayHealth.dotColor("red", hasNotes = false, connected = 0, total = 3))
    }

    @Test
    fun dotIsGreyWhileDisconnectedOrPaused() {
        assertEquals("gray", FeedRelayHealth.dotColor("gray", hasNotes = true, connected = 0, total = 3))
    }
}
