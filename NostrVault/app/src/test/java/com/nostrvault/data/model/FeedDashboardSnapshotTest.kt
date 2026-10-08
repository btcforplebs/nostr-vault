package com.nostrvault.data.model

import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

/** The feed dashboard's cards, from one load of your follows' last 24 hours. */
class FeedDashboardSnapshotTest {

    private val now = 1_800_000_000L
    private val since = now - FeedDashboardSnapshot.WINDOW_SECONDS
    private val me = "f".repeat(64)
    private val alice = "a".repeat(64)
    private val bob = "b".repeat(64)
    private val carol = "c".repeat(64)
    private val stranger = "d".repeat(64)
    private val follows = setOf(alice, bob, carol)
    private var nextId = 0

    private fun id() = (nextId++).toString().padStart(64, '0')

    private fun event(
        pubkey: String,
        kind: Int = 1,
        content: String = "hello",
        tags: List<List<String>> = emptyList(),
        createdAt: Long = now - 60,
        id: String = id(),
    ) = DashboardEvent(id, pubkey, kind, createdAt, content, tags)

    private fun build(
        events: List<DashboardEvent>,
        zaps: List<DashboardEvent> = emptyList(),
        followers: FollowerSnapshot? = null,
        blocked: Set<String> = emptySet(),
    ) = FeedDashboardSnapshot.build(events, zaps, followers, follows, me, blocked, since, now)

    @Test
    fun `posts and people count only follows, inside the window, once each`() {
        val repeated = event(alice)
        val s = build(
            listOf(
                repeated, repeated,
                event(alice, kind = 6, content = ""),
                event(bob),
                event(stranger),
                event(carol, createdAt = since - 1),
            ),
        )
        assertEquals(3, s.posts)
        assertEquals(2, s.activePeople)
        assertEquals(listOf(alice, bob), s.mostActive.map { it.id })
        assertEquals(2, s.mostActive.first().count)
    }

    @Test
    fun `blocked follows are left out`() {
        val s = build(listOf(event(alice), event(bob)), blocked = setOf(bob))
        assertEquals(1, s.posts)
        assertEquals(listOf(alice), s.mostActive.map { it.id })
    }

    @Test
    fun `a trend needs two people, not one person tagging twice`() {
        val s = build(
            listOf(
                event(alice, tags = listOf(listOf("t", "Bitcoin"))),
                event(bob, tags = listOf(listOf("t", "bitcoin"))),
                event(carol, tags = listOf(listOf("t", "solo"))),
                event(carol, tags = listOf(listOf("t", "solo"))),
            ),
        )
        assertEquals(listOf(FeedDashboardSnapshot.Ranked("bitcoin", 2)), s.trending)
    }

    @Test
    fun `popular counts distinct follows who liked, reposted or quoted`() {
        val post = event(stranger, createdAt = since - 10_000)
        val single = id()
        val s = build(
            listOf(
                event(alice, kind = 7, content = "+", tags = listOf(listOf("e", post.id))),
                event(alice, kind = 7, content = "🔥", tags = listOf(listOf("e", post.id))),
                event(bob, kind = 6, content = "", tags = listOf(listOf("e", post.id))),
                event(carol, kind = 7, content = "-", tags = listOf(listOf("e", post.id))),
                event(stranger, kind = 7, content = "+", tags = listOf(listOf("e", post.id))),
                event(carol, kind = 7, content = "+", tags = listOf(listOf("e", single))),
            ),
        )
        assertEquals(1, s.popular.size)
        assertEquals(post.id, s.popular[0].id)
        assertEquals(2, s.popular[0].people)
        // The post itself is older than a day: fetched afterwards.
        assertNull(s.popular[0].note)
        val filled = s.withPopularNotes(listOf(post))
        assertEquals(post.id, filled.popular[0].note?.id)
        // A post no relay returned is dropped rather than shown empty.
        assertTrue(s.withPopularNotes(emptyList()).popular.isEmpty())
    }

    @Test
    fun `recipes are not counted as articles, and empty tiles are hidden`() {
        val s = build(
            listOf(
                event(alice, kind = 30023, tags = listOf(listOf("title", "Essay"))),
                event(bob, kind = 30023, tags = listOf(listOf("title", "Soup"), listOf("t", "zapcooking"))),
                event(carol, kind = 30023, tags = listOf(listOf("title", "Pie"), listOf("t", "zapcooking-dessert"))),
            ),
        )
        assertEquals(listOf("Articles", "Recipes"), s.tiles.map { it.label })
        assertEquals(1, s.tiles[0].count)
        assertEquals("Essay", s.tiles[0].preview)
        assertEquals(2, s.tiles[1].count)
    }

    @Test
    fun `a listing edited twice is one listing`() {
        fun listing(at: Long, title: String) = event(
            alice, kind = 30402, createdAt = at, content = "",
            tags = listOf(listOf("d", "bike"), listOf("title", title), listOf("image", "https://x.test/a.jpg"), listOf("price", "40", "USD")),
        )
        val s = build(listOf(listing(now - 500, "Bike"), listing(now - 100, "Bike, cheaper")))
        val tile = s.tiles.single { it.mode == FeedMode.MARKETPLACE }
        assertEquals(1, tile.count)
        assertEquals("Bike, cheaper", tile.preview)
    }

    @Test
    fun `sats add up receipts to me inside the window`() {
        fun receipt(invoice: String, p: String = me, at: Long = now - 60) =
            event(stranger, kind = 9735, content = "", createdAt = at, tags = listOf(listOf("p", p), listOf("bolt11", invoice)))
        val dup = receipt("lnbc210n1p4fakabc")
        val s = build(
            emptyList(),
            zaps = listOf(
                dup, dup,
                receipt("lnbc1000n1p4fakabc"),
                receipt("lnbc5000n1p4fakabc", p = alice),
                receipt("lnbc5000n1p4fakabc", at = since - 1),
                receipt("not-an-invoice"),
            ),
        )
        assertEquals(121L, s.satsReceived)
    }

    @Test
    fun `new followers come from the ledger, not from old or spam follows`() {
        val ledger = FollowerSnapshot(
            counts = FollowerSnapshot.Counts(),
            followers = listOf(
                FollowerSnapshot.Entry(alice, tier = "trusted", following = true, followedAt = now - 100),
                FollowerSnapshot.Entry(bob, tier = "trusted", following = true, existing = true, followedAt = now - 100),
                FollowerSnapshot.Entry(carol, tier = "spam", following = true, followedAt = now - 100),
                FollowerSnapshot.Entry(stranger, tier = "others", following = true, followedAt = since - 100),
            ),
        )
        assertEquals(1, build(emptyList(), followers = ledger).newFollowers)
        assertEquals(0, build(emptyList(), followers = null).newFollowers)
    }

    @Test
    fun `music counts posts with a Wavlake track link`() {
        val s = build(
            listOf(
                event(alice, content = "listen https://wavlake.com/track/0b5e7c1e-6d3f-4a8e-9b1a-2f3c4d5e6f70"),
                event(bob, content = "wavlake.com is nice"),
            ),
        )
        assertEquals(1, s.tiles.single { it.mode == FeedMode.MUSIC }.count)
    }
}
