package com.nostrvault.relay

import com.nostrvault.relay.RelayMatrix.Job
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
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

    // Never connect

    @Test
    fun `blocking removes from every job once`() {
        val (after, blocked) = RelayMatrix.blocking("wss://a.example/", lists, listOf("wss://x.example"))
        assertFalse(RelayMatrix.rows(after).any { it.id == "wss://a.example" })
        assertEquals(listOf("wss://x.example", "wss://a.example"), blocked)
        assertEquals(blocked, RelayMatrix.blocking("WSS://A.example", after, blocked).second)
        assertEquals(listOf("wss://x.example"), RelayMatrix.unblocking("wss://A.example/", blocked))
    }

    @Test
    fun `blocklist matches the host and exact paths`() {
        val blocked = listOf("wss://bad.example/", "wss://host.example/private")
        assertTrue(RelayBlocklist.isBlocked("wss://bad.example", blocked))
        assertTrue(RelayBlocklist.isBlocked("WSS://Bad.example/inbox", blocked))
        assertTrue(RelayBlocklist.isBlocked("wss://host.example/private/", blocked))
        assertFalse(RelayBlocklist.isBlocked("wss://host.example", blocked))
        assertFalse(RelayBlocklist.isBlocked("wss://good.example", blocked))
        // Another port on the same host is another relay.
        assertFalse(RelayBlocklist.isBlocked("wss://bad.example:8443", blocked))
    }

    @Test
    fun `blocklist ignores local relays`() {
        val blocked = listOf("ws://127.0.0.1:4869", "wss://localhost", "wss://bad.example:7777")
        assertFalse(RelayBlocklist.isBlocked("ws://127.0.0.1:4869", blocked))
        assertFalse(RelayBlocklist.isBlocked("ws://127.0.0.1:3355/inbox", blocked))
        assertFalse(RelayBlocklist.isBlocked("wss://localhost/inbox", blocked))
        assertTrue(RelayBlocklist.isBlocked("wss://bad.example:7777/x", blocked))
        assertFalse(RelayBlocklist.isBlocked("wss://bad.example", blocked))
    }

    // Recommended

    @Test
    fun `follow suggestions rank by follows and skip taken`() {
        val outbox = mapOf(
            "p1" to listOf("wss://popular.example", "wss://a.example", "wss://once.example"),
            "p2" to listOf("wss://popular.example/", "wss://Popular.example", "wss://blocked.example"),
            "p3" to listOf("wss://popular.example", "wss://second.example", "wss://blocked.example"),
            "p4" to listOf("wss://second.example", "ws://127.0.0.1:4869", "wss://x.onion"),
            "p5" to listOf("wss://localhost.example"),
        )
        val suggestions = RelayMatrix.followSuggestions(
            listOf("p1", "p2", "p3", "p4", "p4"), outbox, lists, listOf("wss://blocked.example"))
        assertEquals(
            listOf(
                RelayMatrix.FollowSuggestion("wss://popular.example", 3),
                RelayMatrix.FollowSuggestion("wss://second.example", 2),
            ),
            suggestions,
        )
        assertEquals(1, RelayMatrix.followsWithRelayLists(listOf("p1", "p9"), outbox))
    }

    @Test
    fun `fastest sorts answered relays and skips taken`() {
        val ms = mapOf("wss://slow.example" to 400, "wss://quick.example" to 90, "wss://a.example" to 10)
        val fastest = RelayMatrix.fastest(
            listOf("wss://slow.example", "wss://down.example", "wss://quick.example/", "wss://a.example", "wss://gone.example"),
            ms, lists, listOf("wss://gone.example"))
        assertEquals(listOf("wss://quick.example", "wss://slow.example"), fastest)
    }

    @Test
    fun `public relay`() {
        assertTrue(RelayMatrix.isPublicRelay("wss://relay.damus.io"))
        listOf("ws://relay.damus.io", "wss://localhost", "wss://abc.onion", "wss://192.168.1.4",
            "wss://172.20.0.1", "wss://10.0.0.1:4848", "wss://vault.local", "wss://nodots").forEach {
            assertFalse(it, RelayMatrix.isPublicRelay(it))
        }
        assertTrue(RelayMatrix.isPublicRelay("wss://172.40.0.1"))
    }

    @Test
    fun `fallback problem text names the real fallbacks`() {
        assertTrue(RelayMatrix.Problem.NoWrite.detail.contains("relay.btcforplebs.com"))
        assertTrue(RelayMatrix.Problem.NoRead.detail.contains("relay.primal.net"))
    }

    @Test
    fun `search is a grid column`() {
        assertTrue(Job.SEARCH in Job.columns)
        assertFalse(Job.SEARCH in Job.advanced)
        assertEquals(Job.entries.toSet(), (Job.columns + Job.advanced).toSet())
    }

    @Test
    fun `an edit probes only relays with no speed yet`() {
        val known = setOf(RelayMatrix.key("wss://a.example"), RelayMatrix.key("wss://b.example"))
        assertEquals(listOf("wss://new.example"),
            RelayMatrix.needingProbe(listOf("wss://A.example/", "wss://b.example", "wss://new.example", ""), known))
    }
}
