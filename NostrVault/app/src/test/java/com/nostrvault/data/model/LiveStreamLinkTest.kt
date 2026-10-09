package com.nostrvault.data.model

import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Test

/** [QuoteRef.liveStreamCoordinate]: which web links name a live stream. */
class LiveStreamLinkTest {

    private val host = "d".repeat(64)

    private val decoder = object : QuoteRef.Decoder {
        override fun noteToHex(note1: String): String? = null
        override fun neventToHex(nevent1: String): String? = null
        override fun naddrToCoordinate(naddr1: String) = when (naddr1) {
            "naddr1live" -> QuoteRef.Coordinate(30311, host, "show")
            "naddr1article" -> QuoteRef.Coordinate(30023, host, "post")
            else -> null
        }
    }

    private val expected = "naddr:30311:$host:show"

    @Test
    fun `zap stream, shosho and njump links all name the stream`() {
        assertEquals(expected, QuoteRef.liveStreamCoordinate("https://zap.stream/naddr1live", decoder))
        assertEquals(expected, QuoteRef.liveStreamCoordinate("https://shosho.live/live/naddr1live", decoder))
        assertEquals(expected, QuoteRef.liveStreamCoordinate("https://njump.me/naddr1live?ref=x#top", decoder))
    }

    @Test
    fun `the naddr is matched case-insensitively`() {
        assertEquals(expected, QuoteRef.liveStreamCoordinate("https://zap.stream/NADDR1LIVE", decoder))
    }

    @Test
    fun `an naddr of another kind is not a stream`() {
        assertNull(QuoteRef.liveStreamCoordinate("https://njump.me/naddr1article", decoder))
    }

    @Test
    fun `an naddr in the host or query is ignored`() {
        assertNull(QuoteRef.liveStreamCoordinate("https://example.com/?a=naddr1live", decoder))
        assertNull(QuoteRef.liveStreamCoordinate("https://example.com", decoder))
        assertNull(QuoteRef.liveStreamCoordinate("not a url", decoder))
    }
}
