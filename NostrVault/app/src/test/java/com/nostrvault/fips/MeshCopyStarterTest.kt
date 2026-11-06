package com.nostrvault.fips

import kotlinx.coroutines.test.TestScope
import kotlinx.coroutines.test.runTest
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

/**
 * B hands the signed start to the engine (StartCopyFromC), which makes the start call and fetches; nothing waits
 * in a file for a reader that never comes (Tron, #1784). A cut copy resumes and a copied device gets a catch-up.
 */
class MeshCopyStarterTest {
    private val peer = "npub1" + "a".repeat(58)
    private val link = "ws://127.0.0.1:41234/" + "t".repeat(32)
    private var now = 1_767_000_000L

    private class FakeEngine : MeshCopyStarter.Engine {
        val starts = mutableListOf<Triple<String, String, String>>()
        val syncs = mutableListOf<Pair<String, String>>()
        val answers = ArrayDeque<Int>()
        override fun startCopyFrom(peer: String, base: String, startAuth: String): Int {
            starts += Triple(peer, base, startAuth)
            return answers.removeFirstOrNull() ?: MeshCopyV2.RUN_STARTED
        }
        override fun copySync(peer: String, base: String): Int {
            syncs += peer to base
            return MeshCopyV2.RUN_STARTED
        }
    }

    private class MemoryStore(var r: MeshCopyV2.Record = MeshCopyV2.Record()) : MeshCopyStarter.RecordStore {
        override fun load() = r
        override fun save(r: MeshCopyV2.Record) { this.r = r }
    }

    private val engine = FakeEngine()
    private val store = MemoryStore()
    private val signed = mutableListOf<List<List<String>>>()
    private var setupDone = true

    private fun TestScope.starter() = MeshCopyStarter(
        link = { link },
        sign = { tags -> signed += tags; "c2lnbmVk" },
        engine = engine,
        records = store,
        setupDone = { setupDone },
        scope = this,
        nowS = { now },
    )

    @Test
    fun `the start goes to the engine with the signed proof and the link's secret path`() = runTest {
        val s = starter()
        assertEquals(MeshCopyStarter.Result.Started, s.start(peer, link, "Studio Mac"))
        assertEquals(listOf(Triple(peer, link.replaceFirst("ws://", "http://"), "c2lnbmVk")), engine.starts)
        // Signed for the base only (the link secret never leaves this phone), for A's mesh npub, no device tag.
        assertEquals(
            listOf(listOf("u", "http://127.0.0.1:41234/copy/v2/start"), listOf("method", "POST"), listOf("p", peer)),
            signed.single(),
        )
        // The engine holds the token now: a cut copy resumes without a new proof.
        assertEquals(MeshCopyV2.Record.Pending(peer, "Studio Mac", freshStart = false), store.r.pending)
    }

    @Test
    fun `a relay still coming up is retried, with a fresh signature each time`() = runTest {
        val s = starter()
        engine.answers += listOf(MeshCopyV2.RUN_RELAY_NOT_RUNNING, MeshCopyV2.RUN_RELAY_NOT_RUNNING)
        assertEquals(MeshCopyStarter.Result.Started, s.start(peer, link, "Studio Mac"))
        assertEquals(3, engine.starts.size)
        assertEquals(3, signed.size)
    }

    @Test
    fun `a signer that says no hands nothing to the engine`() = runTest {
        val s = MeshCopyStarter({ link }, { null }, engine, store, { true }, this, { now })
        assertEquals("auth_refused", (s.start(peer, link, "Studio Mac") as MeshCopyStarter.Result.Failed).code)
        assertTrue(engine.starts.isEmpty())
    }

    @Test
    fun `a cut copy resumes on reconnect with the engine's token, not a new start`() = runTest {
        val s = starter()
        s.start(peer, link, "Studio Mac")
        s.onLogLine("COPY stage=failed part=notes bytes=10/100 items=0/1 source=mesh error=unreachable")
        s.reconnectNow()
        assertEquals("", engine.starts.last().third)
        assertEquals(2, engine.starts.size)
        assertEquals(1, signed.size)
    }

    @Test
    fun `a damaged copy starts over on reconnect with a fresh signed start`() = runTest {
        val s = starter()
        s.start(peer, link, "Studio Mac")
        s.onLogLine("COPY stage=failed part=notes bytes=10/100 items=0/1 source=mesh error=hash_mismatch")
        s.reconnectNow()
        assertEquals("c2lnbmVk", engine.starts.last().third)
    }

    @Test
    fun `a done copy is kept and the device gets a catch-up once due`() = runTest {
        val s = starter()
        s.start(peer, link, "Studio Mac")
        s.onLogLine("COPY stage=done part=- bytes=0/0 items=5/5 source=mesh")
        assertNull(store.r.pending)
        s.reconnectNow()
        assertTrue("not due yet", engine.syncs.isEmpty())
        now += MeshCopyV2.SYNC_EVERY_S
        setupDone = false
        s.reconnectNow()
        assertTrue("no catch-up before setup is done", engine.syncs.isEmpty())
        setupDone = true
        s.reconnectNow()
        assertEquals(listOf(peer to link.replaceFirst("ws://", "http://")), engine.syncs)
        assertEquals(now, store.r.copied[peer])
    }

    @Test
    fun `a stop leaves nothing to retry`() = runTest {
        val s = starter()
        s.start(peer, link, "Studio Mac")
        s.onLogLine("COPY stage=failed part=- bytes=1000/1092993024 items=0/0 source=mesh error=needs_space")
        assertNull(store.r.pending)
        s.reconnectNow()
        assertEquals(1, engine.starts.size)
    }

    @Test
    fun `the record survives a restart and holds no token or address`() {
        val r = MeshCopyV2.Record(MeshCopyV2.Record.Pending(peer, "Studio Mac", true), mapOf("npub1b" to 5L))
        val json = r.toJson()
        assertEquals(r, MeshCopyV2.Record.fromJson(json))
        assertFalse(json.contains("127.0.0.1"))
        assertEquals(MeshCopyV2.Record(), MeshCopyV2.Record.fromJson("not json"))
    }
}
