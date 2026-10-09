package com.nostrvault.data.model

import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

/** The Relay tab's Followers list: who shows, in what order, which rows are news, and the red dot. */
class FollowerSnapshotTest {

    private fun entry(
        pubkey: String,
        tier: String = "other",
        following: Boolean = true,
        existing: Boolean = false,
        followedAt: Long = 0,
        follows: Int = 1,
        listAt: Long = 0,
    ) = FollowerSnapshot.Entry(pubkey, tier, following, existing, followedAt, follows, listAt)

    private fun snapshot(vararg entries: FollowerSnapshot.Entry) =
        FollowerSnapshot(FollowerSnapshot.Counts(trusted = 2, others = 3, spam = 7), entries.toList())

    @Test
    fun isNewsOnlyForFollowsTheLedgerWatched() {
        assertTrue(entry("a").isNews) // first follow since the ledger began
        assertTrue(entry("b", existing = true, follows = 2).isNews) // came back
        assertTrue(entry("b", existing = true, follows = 2).isReturning)
        assertFalse(entry("c", existing = true).isNews) // predates the ledger
        assertFalse(entry("d", tier = "spam").isNews)
        assertFalse(entry("e", following = false).isNews) // unfollowed
    }

    @Test
    fun currentDropsSpamAndUnfollowsAndPutsWatchedFollowsFirst() {
        val snap = snapshot(
            // Relay order: newest follow first.
            entry("new2", followedAt = 200, listAt = 10),
            entry("back", existing = true, follows = 3, followedAt = 150, listAt = 5),
            entry("spam", tier = "spam", followedAt = 140, listAt = 999),
            entry("gone", following = false, followedAt = 130, listAt = 998),
            entry("new1", followedAt = 100, listAt = 1),
            entry("old-a", existing = true, listAt = 50),
            entry("old-b", existing = true, tier = "trusted", listAt = 80),
            entry("old-c", existing = true, listAt = 60),
        )
        assertEquals(
            listOf("new2", "back", "new1", "old-b", "old-c", "old-a"),
            snap.current.map { it.pubkey },
        )
    }

    @Test
    fun newCapsAtOneHundredAndAllIsUncapped() {
        val many = (0 until 150).map { i -> entry("pk$i", existing = true, listAt = i.toLong()) }
        val snap = FollowerSnapshot(FollowerSnapshot.Counts(others = 150), many)
        val new = snap.entries(VaultFollowersFilter.NEW)
        assertEquals(FollowerSnapshot.NEW_LIMIT, new.size)
        assertEquals("pk149", new.first().pubkey) // newest list first
        assertEquals(150, snap.entries(VaultFollowersFilter.ALL).size)
    }

    @Test
    fun summaryCountsTrustedPlusOthersNotSpam() {
        assertEquals(5, snapshot().counts.total)
    }

    @Test
    fun dotLightsOnlyForWatchedFollowsAfterSeen() {
        val snap = snapshot(
            entry("old", existing = true, followedAt = 500), // not news, however recent
            entry("spam", tier = "spam", followedAt = 500),
            entry("new", followedAt = 300),
        )
        assertTrue(snap.hasNewSince(0))
        assertTrue(snap.hasNewSince(299))
        assertFalse(snap.hasNewSince(300))
        assertFalse(snapshot(entry("old", existing = true, followedAt = 900)).hasNewSince(0))
    }

    @Test
    fun parsesTheGoSnapshotJson() {
        val raw = """
            {"owner":"ab","seeded_at":1,"counts":{"trusted":1,"others":1,"spam":1,"unfollowed":0},
             "followers":[
              {"pubkey":"p1","tier":"trusted","following":true,"existing":false,"first_seen":5,
               "followed_at":300,"follows":1,"list_at":300,"list_size":12,"churn_24h":0},
              {"pubkey":"p2","tier":"spam","following":true,"existing":true,"first_seen":5,
               "followed_at":0,"follows":1,"list_at":9,"list_size":9000,"churn_24h":40}
             ]}
        """.trimIndent()
        val snap = FollowerSnapshot.parse(raw)
        assertNotNull(snap)
        snap!!
        assertEquals(2, snap.counts.total)
        assertEquals(listOf("p1"), snap.current.map { it.pubkey })
        assertEquals(300L, snap.current.single().followedAt)
    }

    @Test
    fun errorAndEmptyPayloadsParseToNull() {
        assertNull(FollowerSnapshot.parse("""{"error":"relay not running"}"""))
        assertNull(FollowerSnapshot.parse(null))
        assertNull(FollowerSnapshot.parse("not json"))
        // A ledger with no followers marshals `followers` as null.
        val empty = FollowerSnapshot.parse("""{"counts":{"trusted":0,"others":0,"spam":0,"unfollowed":0},"followers":null}""")
        assertNotNull(empty)
        assertTrue(empty!!.current.isEmpty())
    }
}
