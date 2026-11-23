package com.nostrvault.fips

import kotlinx.coroutines.test.StandardTestDispatcher
import kotlinx.coroutines.test.TestScope
import kotlinx.coroutines.test.runCurrent
import kotlinx.coroutines.test.runTest
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

/**
 * The trust rank nudge, and a phone relearning the devices it copied from when it never read the first copy's done
 * line (LogePhone, 2026-11-23: its record was empty, so it never caught up and never got the Mac's rank).
 */
class MeshRankNudgeTest {
    private val mac = "npub1" + "a".repeat(58)
    private val link = "ws://127.0.0.1:41234/" + "t".repeat(32)
    private var now = 1_767_000_000L

    private class FakeEngine(var held: List<String> = emptyList()) : MeshCopyStarter.Engine {
        val syncs = mutableListOf<String>()
        override fun startCopyFrom(peer: String, base: String, startAuth: String) = MeshCopyV2.RUN_STARTED
        override fun copySync(peer: String, base: String, filesToo: Boolean): Int {
            syncs += peer
            return MeshCopyV2.RUN_STARTED
        }
        override fun heldPeers() = held
    }

    private class MemoryStore(var r: MeshCopyV2.Record = MeshCopyV2.Record()) : MeshCopyStarter.RecordStore {
        override fun load() = r
        override fun save(r: MeshCopyV2.Record) { this.r = r }
    }

    private val engine = FakeEngine()
    private val store = MemoryStore()

    private fun TestScope.starter() = MeshCopyStarter(
        link = { link },
        sign = { "c2lnbmVk" },
        engine = engine,
        records = store,
        setupDone = { true },
        scope = this,
        nowS = { now },
        io = StandardTestDispatcher(testScheduler),
    )

    @Test
    fun `the engine's done line is read`() {
        val line = "2026/11/23 10:54:52 COPY stage=done part=- bytes=0/0 items=29373/29373 source=mesh notes=24686 " +
            "messages=3191 files=1496 left_out=0 not_caught_up="
        assertEquals("done", MeshCopyV2.parseLine(line)?.stage)
    }

    @Test
    fun `ready lines and the held list`() {
        assertEquals(mac, MeshRankNudge.readyPeer("2026/11/23 12:00:00 RANK_READY peer=$mac"))
        assertNull(MeshRankNudge.readyPeer("RANK_READY peer=npub1short"))
        assertNull(MeshRankNudge.readyPeer("xRANK_READY peer=$mac"))
        assertEquals(listOf(mac), MeshRankNudge.parseHeld("[\"$mac\"]"))
        assertEquals(emptyList<String>(), MeshRankNudge.parseHeld("not json"))
    }

    @Test
    fun `a device the record lost gets a catch-up on reconnect`() = runTest {
        engine.held = listOf(mac)
        val s = starter()
        s.reconnectNow()
        assertEquals(listOf(mac), engine.syncs)
        assertTrue(mac in store.r.copied)
    }

    @Test
    fun `a nudge catches up now even when not due`() = runTest {
        store.r = MeshCopyV2.Record(copied = mapOf(mac to now))
        val s = starter()
        s.reconnectNow()
        assertEquals(emptyList<String>(), engine.syncs) // caught up a moment ago: not due
        s.onLogLine("2026/11/23 12:00:00 RANK_READY peer=$mac")
        runCurrent()
        assertEquals(listOf(mac), engine.syncs)
    }

    @Test
    fun `a nudge from a device this one never copied from does nothing`() = runTest {
        val s = starter()
        s.onLogLine("2026/11/23 12:00:00 RANK_READY peer=$mac")
        runCurrent()
        assertEquals(emptyList<String>(), engine.syncs)
    }
}
