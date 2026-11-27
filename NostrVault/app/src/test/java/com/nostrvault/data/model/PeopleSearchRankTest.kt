package com.nostrvault.data.model

import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

/** The shared people order (search plan §1a, D3). Mirrors iOS PeopleSearchRankTests (A3) case for case. */
class PeopleSearchRankTest {
    private fun key(n: Int) = "%064x".format(n)
    private fun p(n: Int, displayName: String? = null, name: String? = null, nip05: String? = null, about: String? = null) =
        PeopleSearchRank.Person(key(n), displayName, name, nip05, about)

    private fun rank(
        people: List<PeopleSearchRank.Person>,
        query: String,
        circle: PeopleSearchRank.Circle,
        blocked: Set<String> = emptySet(),
        keepUnmatched: Boolean = false,
        limit: Int? = null,
    ) = PeopleSearchRank.rank(people, query, circle, blocked, keepUnmatched, limit) { it }.map { it.pubkey }

    private fun copy(people: Map<String, TrustRankCopy.Person>) =
        TrustRankCopy(account = key(0), builtAt = 1, maxHop = 6, viewBar = 55.0, floor = 0.0, people = people)

    private fun circle(
        own: Set<String> = emptySet(),
        follows: Set<String> = emptySet(),
        web: Set<String> = emptySet(),
        copy: TrustRankCopy? = null,
        thread: Set<String> = emptySet(),
    ) = PeopleSearchRank.Circle(own, follows, web, copy, thread)

    // ── Closeness ──

    @Test fun youThenFollowsThenWebThenFurtherThenOutside() {
        val people = (1..5).map { p(it, name = "alice") }
        val c = circle(own = setOf(key(5)), follows = setOf(key(4)), web = setOf(key(3)),
            copy = copy(mapOf(key(2) to TrustRankCopy.Person(40.0, 3))))
        assertEquals(listOf(key(5), key(4), key(3), key(2), key(1)), rank(people, "alice", c))
    }

    /** Logen 5d1ce4cb #6: 3+ steps away is inside your web. */
    @Test fun threeStepsAwayIsInside() {
        val c = circle(copy = copy(mapOf(key(1) to TrustRankCopy.Person(10.0, 4), key(2) to TrustRankCopy.Person(10.0, 2))))
        assertTrue(PeopleSearchRank.isInside(key(1), c))
        assertEquals(PeopleSearchRank.Tier.FURTHER, PeopleSearchRank.tier(key(1), c))
        assertEquals(PeopleSearchRank.Tier.WEB, PeopleSearchRank.tier(key(2), c))
        assertFalse(PeopleSearchRank.isInside(key(3), c))
    }

    @Test fun threadPeopleComeFirstWhenGiven() {
        val people = listOf(p(1, name = "bob"), p(2, name = "bobby"))
        assertEquals(listOf(key(2), key(1)), rank(people, "bob", circle(follows = setOf(key(1)), thread = setOf(key(2)))))
    }

    @Test fun ownKeysMatchInAnyCase() {
        assertEquals(PeopleSearchRank.Tier.YOU, PeopleSearchRank.tier(key(7), circle(own = setOf(key(7).uppercase()))))
    }

    // ── Name match ──

    @Test fun exactThenPrefixThenWordThenContainsThenAbout() {
        val people = listOf(
            p(1, about = "I like alice"),
            p(2, name = "Malice"),
            p(3, displayName = "Big Alice"),
            p(4, name = "alicewebber"),
            p(5, displayName = "ALICE"),
        )
        assertEquals(listOf(key(5), key(4), key(3), key(2), key(1)), rank(people, " alice ", circle()))
    }

    @Test fun accentsCaseAndWidthFold() {
        val people = listOf(p(1, name = "Zoëy"), p(2, name = "zoe"))
        assertEquals(listOf(key(2), key(1)), rank(people, "ZOE", circle()))
        assertEquals("abc", PeopleSearchRank.fold(" ＡＢＣ "))
    }

    @Test fun nip05LocalPartIsAName() {
        val people = listOf(p(1, name = "jack dorsey"), p(2, nip05 = "jack@cash.app"))
        assertEquals(listOf(key(2), key(1)), rank(people, "jack", circle()))
        assertEquals(listOf("_@example.com"), p(3, nip05 = "_@example.com").names)
    }

    /** Closeness beats the name: an exact name outside never jumps a follow. */
    @Test fun closerPrefixBeatsFartherExact() {
        val people = listOf(p(1, name = "dan"), p(2, name = "daniel"))
        assertEquals(listOf(key(2), key(1)), rank(people, "dan", circle(follows = setOf(key(2)))))
    }

    // ── Ties ──

    @Test fun trustScoreThenShorterNameThenKey() {
        val people = listOf(p(3, name = "carolyn"), p(2, name = "carol two"), p(1, name = "carol one"), p(4, name = "carolina"))
        val c = circle(copy = copy(mapOf(
            key(4) to TrustRankCopy.Person(90.0, 3),
            key(3) to TrustRankCopy.Person(50.0, 3),
            key(2) to TrustRankCopy.Person(50.0, 3),
            key(1) to TrustRankCopy.Person(50.0, 3),
        )))
        // 4 scores highest; 3 is the shortest of the 50s; 1 before 2 by key.
        assertEquals(listOf(key(4), key(3), key(1), key(2)), rank(people, "car", c))
    }

    // ── Filtering ──

    @Test fun blockedAreDroppedAndEachKeyOnce() {
        val people = listOf(p(1, name = "eve"), p(2, name = "eve"), PeopleSearchRank.Person(key(2).uppercase(), name = "eve"))
        assertEquals(listOf(key(2)), rank(people, "eve", circle(), blocked = setOf(key(1))))
    }

    @Test fun unmatchedAreDroppedUnlessKept() {
        val people = listOf(p(1, name = "frank"), p(2, name = "relay hit"))
        val c = circle(follows = setOf(key(2)))
        assertEquals(listOf(key(1)), rank(people, "fra", c))
        // A relay's own match stays, last in its tier: here a follow, so first.
        assertEquals(listOf(key(2), key(1)), rank(people, "fra", c, keepUnmatched = true))
        assertTrue(rank(people, "  ", c).isEmpty())
    }

    @Test fun limit() {
        val people = (1..5).map { p(it, name = "gus$it") }
        assertEquals(2, rank(people, "gus", circle(), limit = 2).size)
    }

    // ── Outside fold ──

    /** Logen 5d1ce4cb #1: an exact name outside your web stays in the fold. */
    @Test fun exactNameOutsideStaysInTheFold() {
        val people = listOf(p(1, name = "henry"), p(2, name = "henry the cat"))
        val (inside, outside) = PeopleSearchRank.split(people, "henry", circle(follows = setOf(key(2)))) { it }
        assertEquals(listOf(key(2)), inside.map { it.pubkey })
        assertEquals(listOf(key(1)), outside.map { it.pubkey })
        assertTrue(PeopleSearchRank.outsideHoldsTheOnlyExactMatch(inside, outside, "Henry") { it })
    }

    @Test fun foldStaysShutWhenAnExactMatchIsInside() {
        val people = listOf(p(1, name = "ivy"), p(2, name = "Ivy"))
        val (inside, outside) = PeopleSearchRank.split(people, "ivy", circle(follows = setOf(key(2)))) { it }
        assertFalse(PeopleSearchRank.outsideHoldsTheOnlyExactMatch(inside, outside, "ivy") { it })
    }

    // ── Notes share the tiers ──

    @Test fun notesRankWithTheSameInside() {
        val distant = key(9)
        assertEquals(3, SearchRanking.tier(distant, emptySet(), emptySet(), emptySet()) { it == distant })
        assertEquals(SearchRanking.OUTSIDE_TIER, SearchRanking.tier(key(1), emptySet(), emptySet()))
        assertEquals(PeopleSearchRank.Tier.OUTSIDE, SearchRanking.OUTSIDE_TIER)
    }

    @Test fun searchTabOrderRanksPeopleAndNotes() {
        val c = circle(follows = setOf(key(2)), copy = copy(mapOf(key(3) to TrustRankCopy.Person(5.0, 4))))
        val notes = listOf(
            FeedNote.fromEvent("a", key(1), "x", emptyList(), 300, 1),
            FeedNote.fromEvent("b", key(3), "x", emptyList(), 100, 1),
            FeedNote.fromEvent("c", key(2), "x", emptyList(), 200, 1),
        )
        val people = listOf(FeedProfile(key(1), name = "zed"), FeedProfile(key(2), name = "zedd"))
        val out = SearchResultsOrder.apply(GlobalSearchResults(people, notes), "zed", c)
        assertEquals(listOf(key(2), key(1)), out.profiles.map { it.pubkey })
        // Follow, then 3+ steps (inside), then outside, whatever the time.
        assertEquals(listOf("c", "b", "a"), out.notes.map { it.id })
    }
}
