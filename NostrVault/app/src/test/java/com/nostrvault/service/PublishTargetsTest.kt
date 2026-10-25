package com.nostrvault.service

import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Test

class PublishTargetsTest {

    // The app's built-in Write relays when Settings never set any.
    private val appDefaults = listOf(
        "wss://relay.btcforplebs.com",
        "wss://relay.damus.io",
        "wss://relay.snort.social",
    )

    // The 2026-10-25 reply's author: kind 10002 with unmarked r tags (read and write).
    private val authorWrite = listOf(
        "wss://relay.nortis.tech",
        "wss://relay.nostr.build",
        "wss://nos.lol",
        "wss://relay.primal.net",
    )

    @Test
    fun `the author's write relays decide and are all sent to`() {
        val plan = PublishTargets.plan(authorWrite, appDefaults)
        assertEquals(authorWrite, plan.confirmed)
        assertEquals(appDefaults, plan.alsoSend)
    }

    @Test
    fun `an app relay accepting does not count as posted`() {
        // The incident: damus took it, none of the author's relays did.
        val plan = PublishTargets.plan(authorWrite, appDefaults)
        val tally = BroadcastTally(plan.confirmed.size)
        plan.confirmed.forEach { tally.record(it, false, "connection failed") }
        assertEquals(BroadcastTally.Outcome.REFUSED, tally.outcome)
        assertTrue("wss://relay.damus.io" !in plan.confirmed)
    }

    @Test
    fun `no relay list falls back to the app's write relays`() {
        assertEquals(PublishTargets.Plan(appDefaults, emptyList()), PublishTargets.plan(null, appDefaults))
        assertEquals(PublishTargets.Plan(appDefaults, emptyList()), PublishTargets.plan(emptyList(), appDefaults))
    }

    @Test
    fun `a relay in both lists is sent once, as the author's`() {
        val plan = PublishTargets.plan(listOf("wss://nos.lol/", "wss://relay.damus.io"), appDefaults)
        assertEquals(listOf("wss://nos.lol", "wss://relay.damus.io"), plan.confirmed)
        assertEquals(listOf("wss://relay.btcforplebs.com", "wss://relay.snort.social"), plan.alsoSend)
    }

    @Test
    fun `this phone's own relay never decides`() {
        // Loopback always accepts and nobody else can read it.
        val plan = PublishTargets.plan(listOf("ws://127.0.0.1:3355", "wss://nos.lol"), appDefaults)
        assertEquals(listOf("wss://nos.lol"), plan.confirmed)
        assertEquals(PublishTargets.Plan(appDefaults, emptyList()), PublishTargets.plan(listOf("ws://localhost:3355"), appDefaults))
    }
}
