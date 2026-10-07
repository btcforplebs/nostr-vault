package com.nostrvault.ui.screens.profile

import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Test

/** Mirrors iOS FollowListLogicTests. */
class FollowListLogicTest {

    private fun p(key: String, name: String, recency: Long = 0, nip05: String = "") =
        FollowListPerson(pubkey = key, name = name, nip05 = nip05, recency = recency)

    @Test
    fun groupsInOrderFollowsThenTrustThenOutsideAndDropEmpty() {
        val sections = FollowListLogic.sections(
            people = listOf(p("o", "Oscar"), p("w", "Wren"), p("f", "Fay")),
            follows = setOf("f"), webOfTrust = setOf("w", "f"), trustRank = emptyMap(), sort = FollowListSort.NAME,
        )
        assertEquals(
            listOf(FollowListGroup.FOLLOWS, FollowListGroup.WEB_OF_TRUST, FollowListGroup.OUTSIDE),
            sections.map { it.group },
        )
        assertEquals(listOf(listOf("f"), listOf("w"), listOf("o")), sections.map { s -> s.people.map { it.pubkey } })

        val onlyOutside = FollowListLogic.sections(
            people = listOf(p("o", "Oscar")),
            follows = emptySet(), webOfTrust = emptySet(), trustRank = emptyMap(), sort = FollowListSort.NAME,
        )
        assertEquals(listOf(FollowListGroup.OUTSIDE), onlyOutside.map { it.group })
    }

    @Test
    fun rankedExtendedNetworkCountsAsTrustEvenOutsideTheGraph() {
        val sections = FollowListLogic.sections(
            people = listOf(p("x", "Xena")),
            follows = emptySet(), webOfTrust = emptySet(), trustRank = mapOf("x" to 3), sort = FollowListSort.TRUSTED,
        )
        assertEquals(FollowListGroup.WEB_OF_TRUST, sections.first().group)
    }

    @Test
    fun spamIsHiddenAndDuplicatesCollapse() {
        val sections = FollowListLogic.sections(
            people = listOf(p("s", "Spam"), p("a", "Ann"), p("a", "Ann")),
            follows = emptySet(), webOfTrust = emptySet(), trustRank = emptyMap(),
            hidden = setOf("s"), sort = FollowListSort.NAME,
        )
        assertEquals(listOf("a"), sections.flatMap { s -> s.people.map { it.pubkey } })
    }

    @Test
    fun mostTrustedPutsRankedFirstThenNewest() {
        val people = listOf(p("old", "Old", 1), p("new", "New", 9), p("r2", "R2", 0), p("r1", "R1", 0))
        val ordered = FollowListLogic.ordered(people, FollowListSort.TRUSTED, mapOf("r1" to 0, "r2" to 5))
        assertEquals(listOf("r1", "r2", "new", "old"), ordered.map { it.pubkey })
    }

    @Test
    fun recentAndNameOrders() {
        val people = listOf(p("a", "bob", 2), p("b", "Alice", 1), p("c", "carl", 3))
        assertEquals(listOf("c", "a", "b"), FollowListLogic.ordered(people, FollowListSort.RECENT, emptyMap()).map { it.pubkey })
        assertEquals(listOf("b", "a", "c"), FollowListLogic.ordered(people, FollowListSort.NAME, emptyMap()).map { it.pubkey })
    }

    @Test
    fun searchMatchesNameOrNip05CaseInsensitively() {
        val people = listOf(p("a", "Jack", nip05 = "jack@cash.app"), p("b", "Odell", nip05 = "odell@primal.net"))
        val hits = FollowListLogic.sections(
            people = people, follows = emptySet(), webOfTrust = emptySet(), trustRank = emptyMap(),
            sort = FollowListSort.NAME, query = " PRIMAL ",
        )
        assertEquals(listOf("b"), hits.flatMap { s -> s.people.map { it.pubkey } })
    }

    @Test
    fun countTextMarksAPartialCountWithPlus() {
        assertEquals("100+", FollowListLogic.countText(100, more = true))
        assertEquals("100", FollowListLogic.countText(100, more = false))
        assertEquals("—", FollowListLogic.countText(0, more = true))
        assertEquals("1.5k+", FollowListLogic.countText(1_500, more = true))
    }

    @Test
    fun bioLineFlattensLineBreaks() {
        assertEquals("Builder. Bitcoin nostr", FollowListLogic.bioLine("Builder.\n\n  Bitcoin  \nnostr"))
        assertNull(FollowListLogic.bioLine(" \n "))
        assertNull(FollowListLogic.bioLine(null))
    }
}
