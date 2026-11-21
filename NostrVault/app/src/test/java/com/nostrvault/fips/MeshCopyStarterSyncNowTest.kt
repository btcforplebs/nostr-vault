package com.nostrvault.fips

import kotlinx.coroutines.test.StandardTestDispatcher
import kotlinx.coroutines.test.TestScope
import kotlinx.coroutines.test.runCurrent
import kotlinx.coroutines.test.runTest
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

/** Settings › Your Devices › Sync now (3.3.0 D1): every copied-from device in turn, oldest first, due or not. */
class MeshCopyStarterSyncNowTest {
    private val mac = "npub1" + "m".repeat(58)
    private val box = "npub1" + "b".repeat(58)
    private val link = "ws://127.0.0.1:41234/" + "t".repeat(32)
    private var now = 1_767_000_000L
    private var setupDone = true
    private val unreachableFor = mutableSetOf<String>()

    private class Engine : MeshCopyStarter.Engine {
        val syncs = mutableListOf<String>()
        val answers = ArrayDeque<Int>()
        override fun startCopyFrom(peer: String, base: String, startAuth: String) = MeshCopyV2.RUN_STARTED
        override fun copySync(peer: String, base: String, filesToo: Boolean): Int {
            syncs += peer
            return answers.removeFirstOrNull() ?: MeshCopyV2.RUN_STARTED
        }
    }

    private class Store(var r: MeshCopyV2.Record) : MeshCopyStarter.RecordStore {
        override fun load() = r
        override fun save(r: MeshCopyV2.Record) { this.r = r }
    }

    private val engine = Engine()
    // Both synced just now: not due, so only Sync now starts them. The box longest ago.
    private val store = Store(MeshCopyV2.Record(copied = mapOf(mac to now - 60, box to now - 120)))

    private fun TestScope.starter() = MeshCopyStarter(
        link = { npub -> link.takeIf { npub !in unreachableFor } },
        sign = { "c2lnbmVk" },
        engine = engine,
        records = store,
        setupDone = { setupDone },
        scope = this,
        nowS = { now },
        io = StandardTestDispatcher(testScheduler),
    )

    private val done = "COPY stage=done part=- bytes=0/0 items=5/5 source=mesh"

    @Test
    fun `sync now runs each device in turn, the longest ago first`() = runTest {
        val s = starter()
        s.reconnectNow()
        assertEquals(emptyList<String>(), engine.syncs) // not due
        s.syncNow()
        runCurrent()
        assertEquals(listOf(box), engine.syncs)
        assertEquals(box, s.sync.value.running)
        assertEquals(listOf(mac), s.sync.value.queued)
        assertEquals(now, s.sync.value.lastAt[box])
        now += 30
        s.onLogLine(done)
        runCurrent()
        assertEquals(listOf(box, mac), engine.syncs)
        assertEquals(mac, s.sync.value.running)
        assertEquals(emptyList<String>(), s.sync.value.queued)
        s.onLogLine(done)
        runCurrent()
        assertNull(s.sync.value.running)
        assertEquals(now, store.r.copied[mac])
    }

    @Test
    fun `a device that can't be dialed is marked and the next one still runs`() = runTest {
        unreachableFor += box
        val s = starter()
        s.syncNow()
        runCurrent()
        assertEquals(listOf(mac), engine.syncs)
        assertEquals("unreachable", s.sync.value.failed[box])
        assertEquals(mac, s.sync.value.running)
    }

    @Test
    fun `a failed catch-up is shown until the next one starts`() = runTest {
        val s = starter()
        s.syncNow()
        runCurrent()
        s.onLogLine("COPY stage=failed part=notes bytes=10/100 items=0/1 source=mesh error=hash_mismatch")
        runCurrent()
        assertEquals("hash_mismatch", s.sync.value.failed[box])
        s.onLogLine(done) // the mac's
        runCurrent()
        s.syncNow()
        runCurrent()
        s.onLogLine(done)
        runCurrent()
        assertTrue(box !in s.sync.value.failed)
    }

    @Test
    fun `a busy engine keeps the queue for the running one's end`() = runTest {
        engine.answers += MeshCopyV2.RUN_BUSY
        val s = starter()
        s.syncNow()
        runCurrent()
        assertEquals(listOf(box, mac), s.sync.value.queued)
        assertNull(s.sync.value.running)
    }

    @Test
    fun `nothing before setup, and never with the device a copy is pending with`() = runTest {
        setupDone = false
        starter().apply { syncNow(); runCurrent() }
        assertEquals(emptyList<String>(), engine.syncs)
        setupDone = true
        store.r = store.r.copy(pending = MeshCopyV2.Record.Pending(box, "Box", freshStart = false))
        starter().apply { syncNow(); runCurrent() }
        assertEquals(listOf(mac), engine.syncs)
    }
}
