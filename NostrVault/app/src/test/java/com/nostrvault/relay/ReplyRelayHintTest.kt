package com.nostrvault.relay

import org.junit.Assert.assertEquals
import org.junit.Test

/** Mirrors the iOS ReplyRelayHintTests. Case from 2026-11-26: a phone-only poster's hint was their own 127.0.0.1. */
class ReplyRelayHintTest {
    @Test fun phoneOnlyRelayIsNeverTheHint() {
        val config = HavenConfig(ownerNpub = "npub1x", blastrRelays = listOf("ws://192.168.1.4:3355", "wss://relay.damus.io"))
        assertEquals("ws://127.0.0.1", config.nostrURL!!.take(14))
        assertEquals("wss://relay.damus.io", ReplyRelayHint.pick(config))
    }

    @Test fun reachableExternalRelayWins() {
        assertEquals("wss://vault.example.com", ReplyRelayHint.pick("wss://vault.example.com", listOf("wss://relay.damus.io")))
    }

    @Test fun privateExternalRelayFallsThroughToWriteRelays() {
        assertEquals("wss://nos.lol", ReplyRelayHint.pick("wss://box.local", listOf("wss://127.0.0.1:4869", "ws://nos.lol", "wss://nos.lol")))
    }

    @Test fun noReachableRelayGivesEmpty() {
        assertEquals("", ReplyRelayHint.pick(null, listOf("wss://localhost:4869", "wss://10.0.0.2")))
    }
}
