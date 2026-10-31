package com.nostrvault.ui.screens.profile

import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

class ProfileFirstLoadTest {
    private val vault = "ws://127.0.0.1:3355"

    /** The vault's instant empty EOSE (the old bug) does not end the load. */
    @Test fun vaultEoseAloneDoesNotEndTheLoad() {
        val load = ProfileFirstLoad()
        assertFalse(load.onEose(vault))
        assertFalse(load.onEose("wss://relay.primal.net"))
        assertFalse(load.isDone())
    }

    /** Their write relays known: over only once every one of them answered. */
    @Test fun waitsForEveryOutboxRelay() {
        val load = ProfileFirstLoad()
        load.outboxKnown(listOf("wss://their.one", "wss://their.two/"))
        assertFalse(load.onEose(vault))
        assertFalse(load.onEose("wss://their.one"))
        assertTrue(load.onEose("WSS://their.two"))
    }

    /** An outbox relay that answered before the list was settled still counts. */
    @Test fun earlyEoseCountsOnceTheListArrives() {
        val load = ProfileFirstLoad()
        load.onEose("wss://their.one")
        load.outboxKnown(listOf("wss://their.one"))
        assertTrue(load.isDone())
    }

    /** No relay list: waits for nos.lol, primal and snort. */
    @Test fun noListWaitsForTheFallbackRelays() {
        val load = ProfileFirstLoad()
        load.noOutbox()
        assertFalse(load.onEose("wss://nos.lol"))
        assertFalse(load.onEose("wss://relay.primal.net"))
        assertTrue(load.onEose("wss://relay.snort.social"))
    }
}
