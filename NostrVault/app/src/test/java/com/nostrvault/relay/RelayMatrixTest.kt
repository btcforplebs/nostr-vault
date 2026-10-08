package com.nostrvault.relay

import com.nostrvault.relay.RelayMatrix.Job
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Test

/** The relay matrix grid: one row per relay, its jobs read from and written back to the separate lists. */
class RelayMatrixTest {

    private val lists = RelayMatrix.Lists(
        read = listOf("wss://a.example", "wss://b.example"),
        write = listOf("wss://A.example/", "wss://w.example"),
        dms = listOf("wss://d.example"),
        search = listOf("wss://s.example"),
        import = listOf("wss://b.example"),
    )

    @Test
    fun `one row per relay in first-seen order`() {
        val rows = RelayMatrix.rows(lists)
        assertEquals(listOf("wss://a.example", "wss://b.example", "wss://w.example", "wss://d.example", "wss://s.example"), rows.map { it.url })
        assertEquals(setOf(Job.READ, Job.WRITE), rows[0].jobs)
        assertEquals(setOf(Job.READ, Job.IMPORT), rows[1].jobs)
    }

    @Test
    fun `pinned relays have no row`() {
        val rows = RelayMatrix.rows(lists, listOf("wss://a.example/", "wss://D.example", ""))
        assertFalse(rows.any { it.url == "wss://a.example" || it.url == "wss://d.example" })
        assertEquals(3, rows.size)
    }

    @Test
    fun `off removes every spelling, on appends once`() {
        assertEquals(listOf("wss://w.example"), RelayMatrix.setting(Job.WRITE, false, "wss://a.example", lists).write)
        assertEquals(listOf("wss://d.example", "wss://a.example"), RelayMatrix.setting(Job.DMS, true, "wss://a.example/", lists).dms)
        assertEquals(lists, RelayMatrix.setting(Job.WRITE, true, "wss://a.example", lists))
    }

    @Test
    fun `remove and add`() {
        val removed = RelayMatrix.removing("wss://b.example", lists)
        assertEquals(listOf("wss://a.example"), removed.read)
        assertEquals(emptyList<String>(), removed.import)
        val added = RelayMatrix.adding("wss://new.example", lists)
        assertEquals("wss://new.example", added.read.last())
        assertEquals("wss://new.example", added.write.last())
        assertEquals(lists.dms, added.dms)
    }

    @Test
    fun `typed relay url`() {
        assertEquals("wss://relay.example.com", RelayMatrix.relayURL(" relay.example.com/ "))
        assertEquals("ws://127.0.0.1:3355", RelayMatrix.relayURL("ws://127.0.0.1:3355"))
        assertNull(RelayMatrix.relayURL("https://relay.example.com"))
        assertNull(RelayMatrix.relayURL("not a relay"))
        assertNull(RelayMatrix.relayURL(""))
    }

    @Test
    fun problems() {
        val empty = RelayMatrix.Lists(emptyList(), emptyList(), emptyList(), emptyList(), emptyList())
        assertEquals(
            listOf(RelayMatrix.Problem.NoRead, RelayMatrix.Problem.NoWrite, RelayMatrix.Problem.NoDMs, RelayMatrix.Problem.NoSearch),
            RelayMatrix.problems(empty, "", emptyList()),
        )
        assertEquals(
            listOf(RelayMatrix.Problem.OneDM, RelayMatrix.Problem.Unreachable("wss://w.example")),
            RelayMatrix.problems(lists, "", listOf("wss://w.example")),
        )
        assertEquals(emptyList<RelayMatrix.Problem>(), RelayMatrix.problems(lists, "wss://vault.example.com/inbox", emptyList()))
    }

    @Test
    fun `config round trip keeps search on defaults until it changes`() {
        val config = HavenConfig(ownerNpub = "npub1owner").copy(feedRelays = null, inboxRelays = listOf("wss://in.example"), searchRelays = null)
        val read = RelayMatrix.lists(config)
        assertEquals(listOf("wss://in.example"), read.read)
        val same = RelayMatrix.applying(read, config)
        assertNull(same.searchRelays)
        assertEquals(listOf("wss://in.example"), same.feedRelays)
        val changed = RelayMatrix.applying(RelayMatrix.setting(Job.SEARCH, true, "wss://x.example", read), config)
        assertEquals(config.activeSearchRelays + "wss://x.example", changed.searchRelays)
    }
}
