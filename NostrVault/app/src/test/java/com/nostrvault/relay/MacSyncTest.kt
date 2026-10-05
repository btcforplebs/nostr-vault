package com.nostrvault.relay

import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

class MacSyncTest {

    private val mac = "wss://mac.example.com"

    @Test fun macRelayURLMatchesTheRelayEnv() {
        assertEquals("wss://mac.example.com", MacSync.macRelayURL(HavenConfig(macRelayURL = "https://mac.example.com/")))
        assertEquals("ws://192.168.1.5:3355", MacSync.macRelayURL(HavenConfig(macRelayURL = "ws://192.168.1.5:3355")))
        assertEquals("", MacSync.macRelayURL(HavenConfig(macRelayURL = "")))
        val env = RelayConfiguration.generateEnvDictionary(HavenConfig(macRelayURL = "mac.example.com"), java.io.File("/tmp/x"))
        assertEquals("wss://mac.example.com", env["MAC_RELAY_URL"])
    }

    @Test fun parsesTheGoStatusFileAndToleratesUnknownKeys() {
        val s = MacSync.parse("""{"mac_url":"wss://mac.example.com","state":"done","method":"negentropy","posts":12,"mentions":3,"missing":0,"started_at":100,"finished_at":200,"future":true}""")!!
        assertEquals("done", s.state)
        assertEquals(12, s.posts)
        assertEquals(200L, s.finishedAt)
        assertNull(MacSync.parse("not json"))
    }

    @Test fun headlinesFollowTheStatus() {
        val done = MacSyncStatus(macURL = mac, state = "done", posts = 5, mentions = 2, missing = 0, startedAt = 100, finishedAt = 200)
        val v = MacSync.view(done, mac, checkRequested = false, nowSec = 1_000) { "D$it" }
        assertEquals("Everything copied · 0 missing", v.headline)
        assertEquals("5 posts and 2 mentions copied. Checked D200.", v.detail)
        assertEquals("done", v.outcome)

        assertEquals("3 still missing", MacSync.view(done.copy(state = "incomplete", missing = 3), mac, false, 1_000).headline)
        assertEquals("Copied (this Mac can't be checked)", MacSync.view(done.copy(missing = -1), mac, false, 1_000).headline)
        assertEquals("Checking with your Mac…", MacSync.view(done, mac, true, 1_000).headline)
    }

    @Test fun aResultForAnotherMacDoesNotCount() {
        val v = MacSync.view(MacSyncStatus(macURL = "wss://old.example.com", state = "done"), mac, false, 1_000)
        assertEquals("Full copy from your Mac hasn't run yet", v.headline)
        assertNull(v.outcome)
    }

    @Test fun aRunningCopyWithAStoppedHeartbeatWasInterrupted() {
        val running = MacSyncStatus(macURL = mac, state = "running", startedAt = 100, updatedAt = 900)
        assertTrue(MacSync.view(running, mac, false, nowSec = 950).running)
        val stale = MacSync.view(running, mac, false, nowSec = 1_000)
        assertFalse(stale.running)
        assertEquals("Copy was interrupted", stale.headline)
    }

    @Test fun aCheckIsPickedUpWhenACopyStartsAfterTheTap() {
        val before = MacSyncStatus(macURL = mac, state = "done", startedAt = 100)
        assertFalse(MacSync.pickedUp(before, before))
        assertTrue(MacSync.pickedUp(before.copy(startedAt = 150), before))
        assertTrue(MacSync.pickedUp(before.copy(state = "running"), before))
    }
}
