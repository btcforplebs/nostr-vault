package com.nostrvault.service

import org.junit.Assert.assertEquals
import org.junit.Test

/** Feed relay states are keyed the same way however the URL was typed (iOS #281). */
class FeedRelayHealthTest {
    @Test
    fun keyIgnoresCaseAndTrailingSlash() {
        assertEquals(FeedRelayHealth.key("wss://b.example"), FeedRelayHealth.key(" wss://B.example/ "))
    }
}
