package com.nostrvault.service

import com.nostrvault.relay.HavenConfig
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Test

class StatsCountEndpointsTest {
    private val owner = "npub1test"

    @Test fun `the vault's own relay is asked on all four endpoints`() {
        val urls = StatsService.countEndpoints(HavenConfig(ownerNpub = owner))
        assertEquals(
            listOf(
                "ws://127.0.0.1:3355",
                "ws://127.0.0.1:3355/inbox",
                "ws://127.0.0.1:3355/private",
                "ws://127.0.0.1:3355/chat",
            ),
            urls,
        )
    }

    @Test fun `a watch-only owner is counted on the public endpoints only`() {
        val urls = StatsService.countEndpoints(HavenConfig(ownerNpub = owner, signingMode = "browse"))
        assertEquals(listOf("ws://127.0.0.1:3355", "ws://127.0.0.1:3355/inbox"), urls)
    }

    @Test fun `an external relay is asked once, not four times`() {
        val config = HavenConfig(ownerNpub = owner, useExternalRelay = true, externalRelayURL = "wss://relay.example.com")
        assertEquals(1, StatsService.countEndpoints(config).size)
    }

    @Test fun `no account means nothing to ask`() {
        assertEquals(emptyList<String>(), StatsService.countEndpoints(HavenConfig()))
    }

    @Test fun `endpoint counts are summed per kind and for the total`() {
        val merged = StatsService.mergeEndpointCounts(
            listOf(
                mapOf(StatsService.TOTAL_KEY to 120, 1 to 100, 7 to 20),
                mapOf(StatsService.TOTAL_KEY to 5, 4 to 5),
                mapOf(StatsService.TOTAL_KEY to 3, 1059 to 3),
                mapOf(StatsService.TOTAL_KEY to 0),
            ),
        )
        assertEquals(mapOf(StatsService.TOTAL_KEY to 128, 1 to 100, 7 to 20, 4 to 5, 1059 to 3), merged)
    }

    @Test fun `one silent endpoint gives no numbers rather than partial ones`() {
        assertNull(StatsService.mergeEndpointCounts(listOf(mapOf(1 to 10), null)))
        assertNull(StatsService.mergeEndpointCounts(emptyList()))
    }
}
