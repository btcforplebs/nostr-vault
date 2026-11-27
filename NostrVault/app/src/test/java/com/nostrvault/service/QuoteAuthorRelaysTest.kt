package com.nostrvault.service

import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Test

/** A quote not found on the author's first 3 write relays is asked of up to 8. */
class QuoteAuthorRelaysTest {
    // The author's kind 10002 from Tidy's finding (11-27): the note sat only on the 7th.
    private val outbox = listOf(
        "wss://relay.damus.io", "wss://nostr.land", "wss://nostr.wine", "ws://127.0.0.1:4869",
        "wss://r4.example", "wss://r5.example", "wss://nostr-02.yakihonne.com",
        "wss://r7.example", "wss://r8.example", "wss://r9.example",
    )

    @Test
    fun secondPassReachesTheSeventhRelayAndSkipsLoopback() {
        val wide = authorRelaysToAsk(outbox, wide = true)
        assertTrue("wss://nostr-02.yakihonne.com" in wide)
        assertEquals(8, wide.size)
        assertTrue(wide.none(NostrService::isLoopbackRelay))
    }

    @Test
    fun firstPassStaysAtThree() {
        assertEquals(outbox.take(3), authorRelaysToAsk(outbox, wide = false))
        assertEquals(emptyList<String>(), authorRelaysToAsk(null, wide = true))
    }
}
