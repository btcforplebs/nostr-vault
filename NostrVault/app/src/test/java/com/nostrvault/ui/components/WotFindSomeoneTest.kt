package com.nostrvault.ui.components

import com.nostrvault.data.model.FeedProfile
import com.nostrvault.data.model.TrustMap
import com.nostrvault.data.model.TrustRankCopy
import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Test

/** The WOT tab's Find someone on the shared ranker (D3; was TrustMap.searchPeople). */
class WotFindSomeoneTest {
    private val me = "me"
    private fun person(key: String, display: String? = null, name: String? = null, nip05: String? = null) =
        FeedProfile(pubkey = key, name = name, displayName = display, nip05 = nip05)

    private fun find(query: String, people: List<FeedProfile>, follows: Set<String> = emptySet(), web: Set<String> = emptySet(),
                     copy: TrustRankCopy? = null, blocked: Set<String> = emptySet(), limit: Int = FIND_SOMEONE_LIMIT) =
        findSomeone(query, people, setOf(me), follows, web, copy, blocked, limit)

    @Test fun matchesDisplayNameNameAndNip05IgnoringCase() {
        val people = listOf(person("1", display = "Alice Smith"), person("2", name = "bob"), person("3", nip05 = "carol@ALICE.com"), person("4", display = "Dave"))
        assertEquals(setOf("1", "3"), find("ALICE", people).map { it.pubkey }.toSet())
        assertEquals(listOf("2"), find("Bo", people).map { it.pubkey })
        assertTrue(find("   ", people).isEmpty())
        assertTrue(find("zed", people).isEmpty())
    }

    @Test fun followsThenWebThenOutsideWithRowTags() {
        val people = listOf(
            person("other", display = "Ann"),
            person("web", display = "Ann Web"),
            person("follow", display = "Joanne"),
            person("followPrefixLong", display = "Annabelle"),
            person("followPrefixShort", display = "Anna"),
        )
        val follows = setOf("follow", "followPrefixLong", "followPrefixShort")
        val hits = find("ann", people, follows, setOf("web"))
        assertEquals(listOf("followPrefixShort", "followPrefixLong", "follow", "web", "other"), hits.map { it.pubkey })
        assertEquals(
            listOf(TrustMap.Tier.FOLLOW, TrustMap.Tier.FOLLOW, TrustMap.Tier.FOLLOW, TrustMap.Tier.WEB, TrustMap.Tier.OTHER),
            hits.map { it.tier },
        )
        // A follow also in the web is still tagged as a follow.
        assertEquals(TrustMap.Tier.FOLLOW, find("joanne", people, follows, follows).single().tier)
    }

    @Test fun threeStepsAwayIsTaggedInYourWeb() {
        val copy = TrustRankCopy(account = me, builtAt = 1, maxHop = 6, viewBar = 55.0, floor = 0.0,
            people = mapOf("far" to TrustRankCopy.Person(3.0, 4)))
        val hits = find("sam", listOf(person("far", name = "sam"), person("out", name = "sam")), copy = copy)
        assertEquals(listOf("far" to TrustMap.Tier.WEB, "out" to TrustMap.Tier.OTHER), hits.map { it.pubkey to it.tier })
    }

    @Test fun blockedAreLeftOut() {
        assertEquals(listOf("2"), find("eve", listOf(person("1", name = "eve"), person("2", name = "eve")), blocked = setOf("1")).map { it.pubkey })
    }

    @Test fun stopsAtTheLimit() {
        val people = (0 until 20).map { person("k$it", display = "Sam $it") }
        assertEquals(8, find("sam", people).size)
        assertEquals(3, find("sam", people, limit = 3).size)
    }
}
