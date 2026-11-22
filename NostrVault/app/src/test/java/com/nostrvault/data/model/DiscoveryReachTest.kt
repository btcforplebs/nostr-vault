package com.nostrvault.data.model

import com.nostrvault.service.FeedFilterEngine
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertNull
import org.junit.Test

/**
 * Settings › Feed › Discovery Reach: the bar over the desktop Vault's rank,
 * who it lets in, the live count, and the gate it widens. iOS
 * `DiscoveryReachTests.swift`.
 */
class DiscoveryReachTest {
    private fun pk(c: Char) = c.toString().repeat(64)
    private val me = pk('a')

    /** b follows (hop 1, 100), c hop 2 at 80, d hop 2 at 50, e hop 3 at 70, f hop 5 at 46. */
    private fun copy(viewBar: Double = 55.0, floor: Double = 45.0): TrustRankCopy {
        val rows = listOf(Triple('b', 100, 1), Triple('c', 80, 2), Triple('d', 50, 2), Triple('e', 70, 3), Triple('f', 46, 5))
            .joinToString(",") { "[\"${pk(it.first)}\",${it.second},${it.third}]" }
        val text = "{\"account\":\"$me\",\"builtAt\":1795300000,\"version\":2,\"maxHop\":5," +
            "\"people\":[$rows],\"viewBar\":$viewBar,\"floor\":$floor}"
        return assertNotNullAndGet(TrustRankCopy.parse(text, me))
    }

    private fun <T> assertNotNullAndGet(value: T?): T { assertNotNull(value); return value!! }

    @Test fun `the bar starts at the file's bar and stays between its floor and 100`() {
        val copy = copy()
        assertEquals(55.0, DiscoveryReach.bar(null, copy), 0.0)
        assertEquals(72.0, DiscoveryReach.bar(72.0, copy), 0.0)
        assertEquals("nobody under the floor reached the phone", 45.0, DiscoveryReach.bar(30.0, copy), 0.0)
        assertEquals("whole steps", 62.0, DiscoveryReach.bar(61.6, copy), 0.0)
        assertEquals("a saved bar out of 0-100 reads as unset", 55.0, DiscoveryReach.bar(250.0, copy), 0.0)
        assertEquals(55.0, DiscoveryReach.bar(Double.NEGATIVE_INFINITY, copy), 0.0)
        assertEquals(55.0, DiscoveryReach.bar(Double.NaN, copy), 0.0)
        assertEquals(45.0..100.0, DiscoveryReach.range(copy))
        assertEquals(46.0..100.0, DiscoveryReach.range(copy(floor = 45.5)))
    }

    @Test fun `the starting bar is saved as unset`() {
        assertNull(DiscoveryReach.saved(55.0, copy()))
        assertEquals(60.0, DiscoveryReach.saved(60.0, copy()))
    }

    @Test fun `the bar lets in everyone two or more hops out at or over it, split by ring`() {
        val copy = copy()
        assertEquals(DiscoveryReach.Admitted(setOf(pk('c')), setOf(pk('e'))), DiscoveryReach.admitted(copy, 55.0))
        assertEquals("at the bar counts", setOf(pk('c'), pk('d')), DiscoveryReach.admitted(copy, 50.0).circle)
        assertEquals(setOf(pk('e'), pk('f')), DiscoveryReach.admitted(copy, 45.0).distant)
        assertEquals(DiscoveryReach.Admitted.NONE, DiscoveryReach.admitted(copy, 100.0))
    }

    @Test fun `the count splits your circle from distant connections`() {
        assertEquals(DiscoveryReach.Count(1, 1), DiscoveryReach.count(copy(), 55.0))
        assertEquals(DiscoveryReach.Count(2, 2), DiscoveryReach.count(copy(), 45.0))
        assertEquals("1 person in your circle and 1 distant connection", DiscoveryReach.countText(DiscoveryReach.Count(1, 1)))
        assertEquals("0 people in your circle and 2 distant connections", DiscoveryReach.countText(DiscoveryReach.Count(0, 2)))
    }

    @Test fun `only Underrated and Discover are widened`() {
        assertEquals(setOf(FeedMode.UNDERRATED, FeedMode.DISCOVERY), DiscoveryReach.modes)
    }

    @Test fun `distant connections are always rationed`() {
        val admitted = DiscoveryReach.Admitted(setOf(pk('c')), setOf(pk('e')))
        assertEquals(setOf(pk('c')) to setOf(pk('e')), DiscoveryReach.gateSets(admitted))
    }

    // ── The gate ─────────────────────────────────────────────────

    @Test fun `ranked people are inside, distant ones loose whatever the reach`() {
        val web = WebGate.Web(own = setOf(me), web = setOf(pk('b')), ranked = setOf(pk('c')), rankedLoose = setOf(pk('e')))
        assertEquals(WebGate.Verdict.INSIDE, WebGate.judge(pk('c'), web, isPublic = { false }))
        assertEquals(WebGate.Verdict.INSIDE, WebGate.judge(pk('c').uppercase(), web, isPublic = { false }))
        assertEquals(WebGate.Verdict.LOOSE, WebGate.judge(pk('e'), web, isPublic = { false }))
        assertEquals(WebGate.Verdict.OUTSIDE, WebGate.judge(pk('f'), web, isPublic = { false }))
        assertEquals("a public key stays out", WebGate.Verdict.OUTSIDE, WebGate.judge(pk('c'), web, isPublic = { true }))
    }

    // ── The feeds ────────────────────────────────────────────────

    private var n = 0
    private fun post(author: Char) = FeedNote.fromEvent(
        id = (n++).toString().padStart(64, '0'), pubkey = pk(author), content = "a post about something ${n}",
        tags = emptyList(), createdAt = 1_700_000_000L + n, kind = 1, verify = { true },
    )

    private fun feed(mode: FeedMode, notes: List<FeedNote>, admitted: DiscoveryReach.Admitted) = FeedFilterEngine.filterFeedNotes(
        notes, mode, emptySet(), showReposts = true, showReplies = true,
        followedPubkeys = setOf(pk('b')), wotPubkeys = setOf(pk('b')), ownPubkeys = setOf(me), discovery = admitted,
    ).map { it.pubkey }

    @Test fun `Discover and Underrated let ranked people in, other feeds do not`() {
        val admitted = DiscoveryReach.Admitted(setOf(pk('c')), emptySet())
        val notes = listOf(post('c'), post('d'))
        assertEquals(listOf(pk('c')), feed(FeedMode.DISCOVERY, notes, admitted))
        assertEquals(listOf(pk('c')), feed(FeedMode.UNDERRATED, notes, admitted))
        assertEquals(emptyList<String>(), feed(FeedMode.GLOBAL, notes, admitted))
        assertEquals(emptyList<String>(), feed(FeedMode.DISCOVERY, notes, DiscoveryReach.Admitted.NONE))
    }

    @Test fun `distant connections get one post each, and the ration's floor at most`() {
        val admitted = DiscoveryReach.Admitted(emptySet(), setOf(pk('e'), pk('f')))
        val notes = List(3) { post('e') } + List(3) { post('f') }
        val shown = feed(FeedMode.DISCOVERY, notes, admitted)
        assertEquals("one post per distant person", 2, shown.size)
        assertEquals(setOf(pk('e'), pk('f')), shown.toSet())
        val many = DiscoveryReach.Admitted(emptySet(), ('g'..'z').map(::pk).toSet())
        val crowd = ('g'..'z').map(::post)
        assertEquals("never more than the ration (floor ${WebGate.LOOSE_FLOOR})", WebGate.LOOSE_FLOOR,
            feed(FeedMode.UNDERRATED, crowd, many).size)
    }
}
