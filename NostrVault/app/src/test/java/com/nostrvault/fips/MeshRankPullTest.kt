package com.nostrvault.fips

import kotlinx.coroutines.test.StandardTestDispatcher
import kotlinx.coroutines.test.TestScope
import kotlinx.coroutines.test.advanceTimeBy
import kotlinx.coroutines.test.runCurrent
import kotlinx.coroutines.test.runTest
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

/** Rank only (Logen 2026-11-25): a paired phone pulls the trust rank from every paired desktop, no first copy needed. */
class MeshRankPullTest {
    private val mac = "npub1" + "m".repeat(58)
    private val box = "npub1" + "b".repeat(58)
    private val link = "ws://127.0.0.1:41234/" + "t".repeat(32)
    private var now = 1_767_000_000L
    private var arrived = 0
    /** Dials that find no link yet, by peer (the mesh still finding it right after the relay starts). */
    private val missesLeft = mutableMapOf<String, Int>()

    private class Engine : MeshCopyStarter.Engine {
        val syncs = mutableListOf<String>()
        val pulls = mutableListOf<Pair<String, String>>()
        override fun startCopyFrom(peer: String, base: String, startAuth: String) = MeshCopyV2.RUN_STARTED
        override fun copySync(peer: String, base: String, filesToo: Boolean): Int { syncs += peer; return MeshCopyV2.RUN_STARTED }
        override fun rankPull(peer: String, base: String, startAuth: String): Int { pulls += peer to startAuth; return MeshCopyV2.RUN_STARTED }
    }

    private class Store(var r: MeshCopyV2.Record) : MeshCopyStarter.RecordStore {
        override fun load() = r
        override fun save(r: MeshCopyV2.Record) { this.r = r }
    }

    private val engine = Engine()
    private val signed = mutableListOf<List<List<String>>>()

    private fun TestScope.starter(store: Store) = MeshCopyStarter(
        link = { npub ->
            val left = missesLeft[npub] ?: 0
            if (left > 0) { missesLeft[npub] = left - 1; null } else link
        },
        sign = { tags -> signed += tags; "c2lnbmVk" },
        engine = engine,
        records = store,
        setupDone = { true },
        scope = this,
        nowS = { now + testScheduler.currentTime / 1000 },
        io = StandardTestDispatcher(testScheduler),
        desktops = { listOf(mac, box) },
        rankArrived = { arrived++ },
    )

    private fun pulled(peer: String, got: Int, error: String = "") =
        "2026/11/25 10:00:00 RANK_PULLED peer=$peer got=$got" + if (error.isEmpty()) "" else " error=$error"

    @Test
    fun `a rank ask that finds no link right after relay start dials again before it fails`() = runTest {
        missesLeft[mac] = 2
        val s = starter(Store(MeshCopyV2.Record()))
        s.reconnectNow()
        runCurrent()
        assertEquals(emptyList<String>(), engine.pulls.map { it.first })
        advanceTimeBy(OtherVaultCopy.DIAL_RETRY_S * 1000 * 2)
        runCurrent()
        assertEquals(listOf(mac), engine.pulls.map { it.first })
        assertTrue(mac !in s.sync.value.failed)
    }

    @Test
    fun `a desktop still not found after the dial window is marked unreachable`() = runTest {
        missesLeft[mac] = Int.MAX_VALUE
        val s = starter(Store(MeshCopyV2.Record()))
        s.reconnectNow()
        advanceTimeBy(OtherVaultCopy.DIAL_WINDOW_S * 1000)
        runCurrent()
        assertEquals("unreachable", s.sync.value.failed[mac])
        assertEquals("the next desktop still runs", listOf(box), engine.pulls.map { it.first })
    }

    @Test
    fun `no first copy - every paired desktop gets a rank pull, one at a time, hourly`() = runTest {
        val store = Store(MeshCopyV2.Record())
        val s = starter(store)
        s.reconnectNow()
        runCurrent()
        assertEquals(listOf(mac), engine.pulls.map { it.first })
        assertEquals("signed for the rank path", "http://127.0.0.1:41234" + MeshRankPull.START_PATH, signed.single()[0][1])
        assertEquals(mac, s.sync.value.running)
        assertEquals(listOf(box), s.sync.value.queued)
        assertNull(s.onLogLine(pulled(mac, 1)))
        runCurrent()
        assertEquals(1, arrived)
        assertEquals(listOf(mac, box), engine.pulls.map { it.first })
        s.onLogLine(pulled(box, 0))
        runCurrent()
        assertNull(s.sync.value.running)
        assertEquals("a rank pull is no copy", emptyMap<String, Long>(), store.r.copied)
        assertEquals(emptyList<String>(), engine.syncs)
        // Not due again inside the hour; due after it.
        s.reconnectNow(); runCurrent()
        assertEquals(2, engine.pulls.size)
        now += MeshRankNudge.RECHECK_EVERY_S
        s.reconnectNow(); runCurrent()
        assertEquals(3, engine.pulls.size)
    }

    @Test
    fun `a copied Mac keeps its catch-up, the box gets the pull`() = runTest {
        val store = Store(MeshCopyV2.Record(copied = mapOf(mac to now - 60)))
        val s = starter(store)
        s.reconnectNow(); runCurrent()
        assertEquals(listOf(box), engine.pulls.map { it.first })
        assertEquals(emptyList<String>(), engine.syncs)
        s.onLogLine(pulled(box, 0)); runCurrent()
        // The nudge: the Mac catches up, the box pulls.
        s.rankReady(mac); runCurrent()
        assertEquals(listOf(mac), engine.syncs)
        s.onLogLine("COPY stage=done part=- bytes=0/0 items=5/5 source=mesh"); runCurrent()
        s.rankReady(box); runCurrent()
        assertEquals(listOf(box, box), engine.pulls.map { it.first })
    }

    @Test
    fun `a failed pull is shown, and a cut one is due again at once`() = runTest {
        val s = starter(Store(MeshCopyV2.Record()))
        s.reconnectNow(); runCurrent()
        s.onLogLine(pulled(mac, 0, "auth_refused")); runCurrent()
        assertEquals("auth_refused", s.sync.value.failed[mac])
        s.onLogLine(pulled(box, 0, "unreachable")); runCurrent()
        assertEquals(0, arrived)
        s.reconnectNow(); runCurrent()
        assertEquals(listOf(mac, box, box), engine.pulls.map { it.first })
    }

    @Test
    fun `the end line as haven-go logs it`() {
        assertEquals(MeshRankPull.Pulled(mac, 1, ""), MeshRankPull.parse(pulled(mac, 1)))
        assertEquals(MeshRankPull.Pulled(mac, 0, "auth_refused"), MeshRankPull.parse(pulled(mac, 0, "auth_refused")))
        assertNull(MeshRankPull.parse("XRANK_PULLED peer=$mac got=1"))
        assertNull(MeshRankPull.parse("RANK_PULLED peer=npub1short got=1"))
        assertTrue(MeshRankPull.startTags("http://127.0.0.1:9", " ") == null)
    }
}
