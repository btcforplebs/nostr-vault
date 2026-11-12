package com.nostrvault.data.model

import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

/** My Web's "New in your web" (twin of iOS WotNewcomersTests). */
class NewInWebTest {
    private fun pk(n: Int) = "%08x".format(n) + "0".repeat(56)

    @Test fun firstLookNotesEveryoneAndShowsNoOne() {
        val kept = NewInWeb.update(listOf(pk(1), pk(2)), null, 100)
        assertTrue(kept.fresh.isEmpty())
        assertEquals(2, kept.known.size)
    }

    @Test fun someoneNewShowsForAWeekWhileVouched() {
        var kept = NewInWeb.update(listOf(pk(1)), null, 0)
        kept = NewInWeb.update(listOf(pk(1), pk(2)), kept, 10)
        assertEquals(listOf(pk(2)), kept.fresh.map { it.pubkey })
        // Still new six days later, gone after seven.
        assertEquals(listOf(pk(2)), NewInWeb.update(listOf(pk(1), pk(2)), kept, 10 + 6 * 86400L).fresh.map { it.pubkey })
        assertTrue(NewInWeb.update(listOf(pk(1), pk(2)), kept, 10 + 7 * 86400L).fresh.isEmpty())
    }

    @Test fun mutedPeopleAreNeverOfferedNorNewlyNotedAndDropOutOnceMuted() {
        val muted = setOf(pk(2))
        val first = NewInWeb.update(listOf(pk(1), pk(2)), null, 1000, muted)
        assertTrue(first.fresh.isEmpty())
        assertEquals("a muted person isn't noted on a first look", setOf(pk(1).take(8)), first.known)
        val r = NewInWeb.update(listOf(pk(1), pk(2)), first, 2000)
        assertEquals(listOf(pk(2)), r.fresh.map { it.pubkey })
        val nowMuted = NewInWeb.update(listOf(pk(1), pk(2)), r, 3000, muted)
        assertTrue("muted after arriving: no longer new", nowMuted.fresh.isEmpty())
        assertTrue("once known they don't come back as new after an unmute",
            NewInWeb.update(listOf(pk(1), pk(2)), nowMuted, 4000).fresh.isEmpty())
    }

    @Test fun someoneWhoDropsOutAndComesBackIsNotNewAgain() {
        var kept = NewInWeb.update(listOf(pk(1), pk(2)), null, 0)
        kept = NewInWeb.update(listOf(pk(1)), kept, 10)
        kept = NewInWeb.update(listOf(pk(1), pk(2)), kept, 20)
        assertTrue(kept.fresh.isEmpty())
    }

    @Test fun keepsAtMostForty() {
        var kept = NewInWeb.update(emptyList(), null, 0)
        kept = NewInWeb.update((1..50).map(::pk), kept, 1)
        assertEquals(NewInWeb.KEPT, kept.fresh.size)
    }

    @Test fun whatIsKeptReadsBackAndJunkIsAFirstLook() {
        var kept = NewInWeb.update(listOf(pk(1)), null, 0)
        kept = NewInWeb.update(listOf(pk(1), pk(2)), kept, 10)
        assertEquals(kept, NewInWeb.fromJson(kept.toJson()))
        assertNull(NewInWeb.fromJson(null))
        assertNull(NewInWeb.fromJson("not json"))
        assertNull(NewInWeb.fromJson("{}"))
    }
}
