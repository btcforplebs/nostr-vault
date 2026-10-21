package com.nostrvault.service

import com.nostrvault.data.model.LiveStream
import com.nostrvault.service.LiveFeedService.GlobalGate
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

/** Live's Global side for an account with no web of trust. iOS LiveChatTests. */
class LiveFeedRulesTest {
    @Test
    fun globalOpensOnlyForAnAccountWithNoWebOfTrust() {
        assertEquals(GlobalGate.Everyone, LiveFeedService.globalGate(null, hasNoWebOfTrustYet = true))
        assertEquals(GlobalGate.NewAccount, LiveFeedService.globalGate(emptySet(), hasNoWebOfTrustYet = true))
        // Graph not read yet: fail closed, an account with follows must not flash unfiltered.
        assertEquals(GlobalGate.Trusted(emptySet()), LiveFeedService.globalGate(emptySet(), hasNoWebOfTrustYet = false))
        assertEquals(GlobalGate.Trusted(setOf("a")), LiveFeedService.globalGate(setOf("a"), hasNoWebOfTrustYet = false))
    }

    /** The real adult stream on the default relays (2026-10-12) had no tag, only a 🔞 in the title. */
    @Test
    fun adultStreamsAreRecognised() {
        assertTrue(LiveFeedService.isAdultStream(listOf(listOf("title", "The weekend grind... 🔞"), listOf("t", "gaming"))))
        assertTrue(LiveFeedService.isAdultStream(listOf(listOf("title", "Late show"), listOf("content-warning", ""))))
        assertTrue(LiveFeedService.isAdultStream(listOf(listOf("title", "Late show"), listOf("t", "NSFW"))))
        assertTrue(LiveFeedService.isAdultStream(listOf(listOf("L", "content-warning"), listOf("l", "nudity", "content-warning"))))
        assertTrue(LiveFeedService.isAdultStream(listOf(listOf("title", "chill stream (NSFW)"))))
        assertTrue(LiveFeedService.isAdultStream(listOf(listOf("summary", "#nsfw after midnight"))))
    }

    @Test
    fun ordinaryStreamsAreNotAdult() {
        assertFalse(LiveFeedService.isAdultStream(listOf(listOf("title", "Noderunners Radio"), listOf("t", "bitcoin"))))
        // A word that merely contains an adult word is not one.
        assertFalse(LiveFeedService.isAdultStream(listOf(listOf("title", "Xxxtentacion tribute"), listOf("summary", "nudestar telescope night"))))
        assertFalse(LiveFeedService.isAdultStream(listOf(listOf("title", "Lightning Goats"), listOf("summary", "pornographic-free goat feeder"))))
        assertFalse(LiveFeedService.isAdultStream(emptyList()))
    }

    /** iOS sorts newest first, not by viewers; a tie falls to the address. */
    @Test
    fun streamsAreOrderedNewestFirst() {
        fun stream(d: String, createdAt: Long, viewers: Int?) = LiveStream(
            hostPubkey = "host", identifier = d, createdAt = createdAt, title = d, summary = null,
            imageUrl = null, streamingUrl = "https://example.com/$d.m3u8", status = "live", participants = viewers,
        )
        val old = stream("old", createdAt = 100, viewers = 900)
        val newest = stream("newest", createdAt = 300, viewers = 1)
        val tieA = stream("a", createdAt = 200, viewers = null)
        val tieB = stream("b", createdAt = 200, viewers = 50)
        val ordered = LiveFeedService.newestFirst(listOf(old, tieA, newest, tieB))
        assertEquals(listOf("newest", "b", "a", "old"), ordered.map { it.identifier })
    }
}
