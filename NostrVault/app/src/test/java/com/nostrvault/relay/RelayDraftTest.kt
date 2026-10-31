package com.nostrvault.relay

import com.nostrvault.relay.RelayDraft.Section
import com.nostrvault.relay.RelayMatrix.Job
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

/** Settings > Relays as a draft: Yours vs App defaults, fixed row order, and what Save publishes. */
class RelayDraftTest {

    // This device: the app's defaults, as Vyram's phone had them.
    private val config = RelayMatrix.Lists(
        read = listOf("wss://relay.damus.io", "wss://relay.primal.net", "wss://relay.snort.social"),
        write = listOf("wss://relay.btcforplebs.com", "wss://relay.damus.io"),
        dms = listOf("wss://relay.btcforplebs.com", "wss://relay.primal.net"),
        search = listOf("wss://search.nos.today"),
        import = listOf("wss://relay.btcforplebs.com", "wss://nostr-pub.wellorder.net"),
    )

    // His published kind 10002 and 10050.
    private val published = RelayDraft.Published(
        read = listOf("wss://nostr.land", "wss://relay.primal.net"),
        write = listOf("wss://relay.primal.net"),
        dms = listOf("wss://inbox.nostr.wine"),
        relayListKnown = true,
        dmListKnown = true,
    )

    private val ownRelay = "wss://vault.example"
    private val ownInbox = "wss://vault.example/inbox"

    private fun start() = RelayDraft.start(config, published, pinned = listOf(ownRelay, ownInbox))
    private fun key(url: String) = RelayMatrix.key(url)
    private fun order(s: RelayDraft.State) = RelayDraft.rows(s).map { it.entry.key }
    private fun section(s: RelayDraft.State, url: String) = s.layout.first { it.key == key(url) }.section

    @Test
    fun `his published relays are Yours and everything else is an App default`() {
        val s = start()
        assertEquals(Section.YOURS, section(s, "wss://nostr.land"))
        assertEquals(Section.YOURS, section(s, "wss://relay.primal.net"))
        assertEquals(Section.YOURS, section(s, "wss://inbox.nostr.wine"))
        assertEquals(Section.DEFAULTS, section(s, "wss://relay.damus.io"))
        assertEquals(Section.DEFAULTS, section(s, "wss://nostr-pub.wellorder.net"))
        // Yours rows come first.
        assertEquals(listOf(Section.YOURS, Section.YOURS, Section.YOURS), s.layout.take(3).map { it.section })
        // His relays are in their jobs even though this device never had them.
        assertEquals(setOf(Job.READ), RelayDraft.jobs(s.draft, key("wss://nostr.land")))
        assertEquals(setOf(Job.DMS), RelayDraft.jobs(s.draft, key("wss://inbox.nostr.wine")))
        assertEquals(0, RelayDraft.changeCount(s))
    }

    @Test
    fun `the vault's own relay and inbox get no row`() {
        val withOwn = published.copy(read = published.read + ownRelay, dms = published.dms + ownInbox)
        val s = RelayDraft.start(config, withOwn, pinned = listOf(ownRelay, ownInbox))
        assertFalse(s.layout.any { it.key == key(ownRelay) || it.key == key(ownInbox) })
        assertFalse(s.draft.read.any { key(it) == key(ownRelay) })
    }

    @Test
    fun `import is a job like the others and every row can be removed`() {
        var s = start()
        val wellorder = key("wss://nostr-pub.wellorder.net")
        assertEquals(setOf(Job.READ, Job.IMPORT).intersect(RelayDraft.jobs(s.draft, wellorder)), setOf(Job.IMPORT))
        s = RelayDraft.toggle(s, wellorder, Job.IMPORT)
        assertTrue(RelayDraft.jobs(s.draft, wellorder).isEmpty())
        s = RelayDraft.remove(start(), wellorder)
        assertFalse(s.draft.import.any { key(it) == wellorder })
        assertTrue(RelayDraft.rows(s).first { it.entry.key == wellorder }.removed)
    }

    @Test
    fun `tapping dots and removing never moves a row`() {
        val s0 = start()
        val before = order(s0)
        var s = s0
        for (row in RelayDraft.rows(s0)) for (job in Job.entries) s = RelayDraft.toggle(s, row.entry.key, job)
        assertEquals(before, order(s))
        // A row with every dot off stays where it was.
        val damus = key("wss://relay.damus.io")
        var off = s0
        Job.entries.forEach { job -> if (job in RelayDraft.jobs(off.draft, damus)) off = RelayDraft.toggle(off, damus, job) }
        assertTrue(RelayDraft.jobs(off.draft, damus).isEmpty())
        assertEquals(before, order(off))
        s = RelayDraft.remove(s0, damus)
        assertEquals(before, order(s))
        s = RelayDraft.undo(s, damus)
        assertEquals(before, order(s))
        assertEquals(RelayDraft.jobs(s0.draft, damus), RelayDraft.jobs(s.draft, damus))
    }

    @Test
    fun `save keeps the order, and only removed rows leave`() {
        val s0 = start()
        val damus = key("wss://relay.damus.io")
        var s = RelayDraft.toggle(s0, key("wss://relay.snort.social"), Job.WRITE)
        s = RelayDraft.remove(s, damus)
        val saved = RelayDraft.saved(s, RelayDraft.plan(s, ownRelay, ownInbox))
        assertEquals(order(s0) - damus, order(saved))
        assertEquals(s0.layout.filter { it.key != damus }.map { it.section }, saved.layout.map { it.section })
        assertEquals(0, RelayDraft.changeCount(saved))
    }

    @Test
    fun `an added relay goes at the end of Yours`() {
        val s = RelayDraft.add(start(), "relay.new.example".let { "wss://$it" }, setOf(Job.READ, Job.WRITE))
        val last = s.layout.last()
        assertEquals(key("wss://relay.new.example"), last.key)
        assertEquals(Section.YOURS, last.section)
        assertEquals(1, RelayDraft.changeCount(s))
    }

    @Test
    fun `nothing is published when nothing changed`() {
        val plan = RelayDraft.plan(start(), ownRelay, ownInbox)
        assertNull(plan.relayListTags)
        assertNull(plan.dmRelays)
        assertTrue(plan.localChanges.isEmpty())
    }

    @Test
    fun `changing App defaults never publishes`() {
        var s = start()
        s = RelayDraft.remove(s, key("wss://relay.damus.io"))
        s = RelayDraft.toggle(s, key("wss://relay.snort.social"), Job.WRITE)
        s = RelayDraft.toggle(s, key("wss://relay.btcforplebs.com"), Job.DMS)
        val plan = RelayDraft.plan(s, ownRelay, ownInbox)
        assertNull(plan.relayListTags)
        assertNull(plan.dmRelays)
        assertEquals(3, plan.localChanges.size)
        assertEquals(setOf(Job.READ, Job.WRITE), plan.localChanges.first { key(it.url) == key("wss://relay.damus.io") }.removed)
    }

    @Test
    fun `a Yours edit publishes only Yours, never the defaults`() {
        val s = RelayDraft.toggle(start(), key("wss://nostr.land"), Job.WRITE)
        val plan = RelayDraft.plan(s, ownRelay, ownInbox)
        val tags = assertNotNullAndGet(plan.relayListTags)
        val urls = tags.map { key(it[1]) }.toSet()
        assertEquals(setOf(key(ownRelay), key("wss://nostr.land"), key("wss://relay.primal.net")), urls)
        assertFalse(key("wss://relay.damus.io") in urls)
        // nostr.land is now Read and Write: no marker.
        assertEquals(listOf("r", "wss://nostr.land"), tags.first { key(it[1]) == key("wss://nostr.land") })
        assertNull(plan.dmRelays)
        assertTrue(plan.relayListChanges.any { key(it.url) == key("wss://nostr.land") && it.added == setOf(Job.WRITE) })
    }

    @Test
    fun `removing his DM relay publishes a 10050 without it, and an emptied one goes out empty`() {
        var s = RelayDraft.add(start(), "wss://dm2.example", setOf(Job.DMS))
        s = RelayDraft.remove(s, key("wss://inbox.nostr.wine"))
        val plan = RelayDraft.plan(s, ownRelay, "")
        assertEquals(listOf("wss://dm2.example"), plan.dmRelays)
        // Default DM relays (btcforplebs, primal-as-default-DM) are not added.
        val emptied = RelayDraft.plan(RelayDraft.remove(start(), key("wss://inbox.nostr.wine")), ownRelay, "")
        assertEquals(emptyList<String>(), emptied.dmRelays)
    }

    @Test
    fun `the vault inbox leads a published DM list`() {
        val s = RelayDraft.add(start(), "wss://dm2.example", setOf(Job.DMS))
        assertEquals(listOf(ownInbox, "wss://inbox.nostr.wine", "wss://dm2.example"), RelayDraft.plan(s, ownRelay, ownInbox).dmRelays)
    }

    @Test
    fun `an unknown published list is never published over`() {
        val unknown = published.copy(relayListKnown = false, dmListKnown = false)
        var s = RelayDraft.start(config, unknown)
        s = RelayDraft.toggle(s, key("wss://nostr.land"), Job.WRITE)
        s = RelayDraft.remove(s, key("wss://inbox.nostr.wine"))
        val plan = RelayDraft.plan(s, ownRelay, ownInbox)
        assertNull(plan.relayListTags)
        assertNull(plan.dmRelays)
        assertTrue(plan.relayListHeld)
        assertTrue(plan.dmListHeld)
    }

    @Test
    fun `adding an App default by hand makes it Yours and publishes it`() {
        val s = RelayDraft.add(start(), "wss://relay.snort.social", setOf(Job.READ, Job.WRITE))
        assertEquals(Section.YOURS, section(s, "wss://relay.snort.social"))
        assertEquals(key("wss://relay.snort.social"), s.layout.last().key)
        val tags = assertNotNullAndGet(RelayDraft.plan(s, ownRelay, ownInbox).relayListTags)
        assertTrue(tags.any { key(it[1]) == key("wss://relay.snort.social") })
    }

    @Test
    fun `search and import on a Yours row stay on this device`() {
        var s = RelayDraft.toggle(start(), key("wss://nostr.land"), Job.SEARCH)
        s = RelayDraft.toggle(s, key("wss://nostr.land"), Job.IMPORT)
        val plan = RelayDraft.plan(s, ownRelay, ownInbox)
        assertNull(plan.relayListTags)
        assertEquals(setOf(Job.SEARCH, Job.IMPORT), plan.localChanges.single().added)
    }

    @Test
    fun `a removed row ignores taps until undo`() {
        val k = key("wss://nostr.land")
        val removed = RelayDraft.remove(start(), k)
        assertEquals(removed, RelayDraft.toggle(removed, k, Job.WRITE))
    }

    @Test
    fun `reset search adds new default rows at the end without moving any`() {
        val s0 = start()
        val s = RelayDraft.resetSearch(s0, listOf("wss://search.nos.today", "wss://relay.vertexlab.io"))
        assertEquals(order(s0), order(s).take(order(s0).size))
        assertEquals(RelayDraft.Entry(key("wss://relay.vertexlab.io"), "wss://relay.vertexlab.io", Section.DEFAULTS), s.layout.last())
    }

    @Test
    fun `a list is settled when found or when half the relays answered without it`() {
        assertTrue(RelayDraft.settled(found = true, asked = 6, answered = 1))
        assertTrue(RelayDraft.settled(found = false, asked = 6, answered = 3))
        assertFalse(RelayDraft.settled(found = false, asked = 6, answered = 2))
        assertFalse(RelayDraft.settled(found = false, asked = 0, answered = 0))
    }

    private fun <T> assertNotNullAndGet(value: T?): T {
        assertNotNull(value)
        return value!!
    }
}
