package com.nostrvault.data.model

import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

class LiveStreamTest {

    private val host = "a".repeat(64)

    private fun stream(vararg tags: Pair<String, String>) =
        LiveStream.from(host, 1_700_000_000L, tags.map { listOf(it.first, it.second) })

    @Test fun `an event without a d tag is not a stream`() {
        assertNull(stream("title" to "No identifier"))
    }

    @Test fun `reads the tags it needs`() {
        val s = stream(
            "d" to "weekly-show",
            "title" to "Weekly Show",
            "summary" to "Every Monday",
            "image" to "https://example.com/cover.jpg",
            "streaming" to "https://example.com/live.m3u8",
            "status" to "LIVE",
            "current_participants" to "42",
        )!!
        assertEquals("Weekly Show", s.title)
        assertEquals(42, s.participants)
        assertEquals("live", s.status)
        assertEquals("30311:$host:weekly-show", s.address)
        assertTrue(s.isPlayableLive)
    }

    @Test fun `unplayable schemes are dropped rather than shown`() {
        // A tile whose URL the player cannot open can only disappoint.
        for (url in listOf("rtmp://example.com/live", "ftp://example.com/x", "zapcast:abc")) {
            val s = stream("d" to "x", "streaming" to url, "status" to "live")!!
            assertNull(url, s.streamingUrl)
            assertFalse(url, s.isPlayableLive)
        }
    }

    @Test fun `ended streams are not playable even with a url`() {
        val s = stream("d" to "x", "streaming" to "https://e/x.m3u8", "status" to "ended")!!
        assertFalse(s.isPlayableLive)
    }

    @Test fun `a missing status with a playable url counts as live`() {
        // A real bucket: a large share of events omit status entirely.
        val s = stream("d" to "x", "streaming" to "https://e/x.m3u8")!!
        assertTrue(s.isPlayableLive)
    }

    @Test fun `no streaming url means nothing to play`() {
        val s = stream("d" to "x", "status" to "live")!!
        assertFalse(s.isPlayableLive)
    }

    @Test fun `blank tag values are treated as absent`() {
        val s = stream("d" to "x", "title" to "   ", "current_participants" to "many")!!
        assertNull(s.title)
        assertNull(s.participants)
    }

    @Test fun `the relays tag names where the chat is`() {
        val s = LiveStream.from(host, 1L, listOf(
            listOf("d", "x"),
            listOf("relays", "wss://relay.damus.io", "wss://nos.lol", "https://not-a-relay"),
        ))!!
        // A stream's own hint is the only trustworthy source of its chat relay
        // — the relay everyone's docs name for this served zero chat when
        // measured. Non-websocket entries are not relays.
        assertEquals(listOf("wss://relay.damus.io", "wss://nos.lol"), s.chatRelays)
    }

    @Test fun `a web page is not a playable stream`() {
        // Seen live 2026-09-26: a youtube.com/live link in `streaming`.
        for (url in listOf("https://youtube.com/live/YbnlF1CRqok", "https://e/watch?v=x.m3u8")) {
            val s = stream("d" to "x", "streaming" to url, "status" to "live")!!
            assertNull(url, s.streamingUrl)
        }
        val signed = stream("d" to "x", "streaming" to "https://e/video.m3u8?token=abc")!!
        assertEquals("https://e/video.m3u8?token=abc", signed.streamingUrl)
    }

    @Test fun `a live event nobody has updated for an hour is off air`() {
        val s = stream("d" to "x", "streaming" to "https://e/x.m3u8", "status" to "live")!!
        assertTrue(s.isOnAirAt(1_700_000_000L + 60 * 60))
        assertFalse(s.isOnAirAt(1_700_000_000L + 60 * 60 + 1))
    }

    @Test fun `a stream past its ends time is off air`() {
        val s = stream("d" to "x", "streaming" to "https://e/x.m3u8", "ends" to "1700000100")!!
        assertTrue(s.isOnAirAt(1_700_000_099L))
        assertFalse(s.isOnAirAt(1_700_000_100L))
    }

    @Test fun `a stream with no relays tag falls back rather than failing`() {
        assertEquals(emptyList<String>(), stream("d" to "x")!!.chatRelays)
    }
}
