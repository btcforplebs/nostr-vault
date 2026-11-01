package com.nostrvault.data.model

import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Assert.assertNull
import org.junit.Assert.assertSame
import org.junit.Test

class AccountUnreadTest {
    private val alice = "a".repeat(64)
    private val bob = "b".repeat(64)

    private fun marker(type: String, id: String, to: String, preview: String = "hi") =
        "type=$type|kind=1|author=${"c".repeat(64)}|id=$id|recipient=$to|preview=$preview"

    @Test fun countsPerRecipient() {
        val u = AccountUnread()
            .record(marker("reply", "1", alice))
            .record(marker("zap", "2", alice))
            .record(marker("mention", "3", bob))
        assertEquals(2, u.count(alice))
        assertEquals(1, u.count(bob))
    }

    @Test fun sameEventCountsOnce() {
        val once = AccountUnread().record(marker("reaction", "1", alice))
        assertSame(once, once.record(marker("reaction", "1", alice)))
        assertEquals(1, once.count(alice))
    }

    @Test fun dmsSummaryAndUnnamedAccountDoNotCount() {
        val u = AccountUnread()
            .record(marker("dm", "1", alice))
            .record(marker("giftwrap", "2", alice))
            .record("type=summary|kind=0|author=|id=|recipient=|preview=4 more new items while you were away")
            .record(marker("reply", "3", ""))
            .record(marker("reply", "4", "npub1notahex"))
        assertEquals(emptyMap<String, List<String>>(), u.ids)
    }

    @Test fun previewCannotForgeFields() {
        val forged = "type=reply|kind=1|author=x|id=1|recipient=$alice|preview=a|recipient=$bob|id=9"
        assertEquals(alice to "1", AccountUnread.parse(forged))
    }

    @Test fun markSeenEmptiesOnlyThatAccount() {
        val u = AccountUnread()
            .record(marker("reply", "1", alice))
            .record(marker("reply", "2", bob))
            .markSeen(alice.uppercase())
        assertEquals(0, u.count(alice))
        assertEquals(1, u.count(bob))
        assertSame(u, u.markSeen(alice))
    }

    @Test fun followersCountOneEach() {
        val u = AccountUnread()
            .record("type=follow|kind=3|author=x|id=f1|recipient=$alice|preview=")
            .record("type=follow|kind=3|author=y|id=f2|recipient=$alice|preview=")
        assertEquals(2, u.count(alice))
    }

    @Test fun capKeepsNewest() {
        var u = AccountUnread()
        repeat(AccountUnread.CAP + 5) { u = u.record(marker("reply", "$it", alice)) }
        assertEquals(AccountUnread.CAP, u.count(alice))
        assertEquals("5", u.ids[alice]?.first())
    }

    @Test fun badgeText() {
        assertNull(AccountUnread.badge(0))
        assertEquals("7", AccountUnread.badge(7))
        assertEquals("99", AccountUnread.badge(99))
        assertEquals("99+", AccountUnread.badge(100))
    }

    @Test
    fun otherAccountDot() {
        var u = AccountUnread()
        val both = listOf(alice, bob)
        assertFalse(u.othersHaveUnread(both, alice))
        // News for the active account alone: its Vault tab has the dot, not the avatar.
        u = u.record(marker("reply", id = "1", to = alice))
        assertFalse(u.othersHaveUnread(both, alice))
        u = u.record(marker("zap", id = "2", to = bob))
        assertTrue(u.othersHaveUnread(both, alice))
        assertTrue(u.othersHaveUnread(both, alice.uppercase()))
        assertTrue(u.othersHaveUnread(both, bob))
        u = u.markSeen(bob)
        assertFalse(u.othersHaveUnread(both, alice))
    }

    @Test
    fun removedAccountDoesNotHoldTheDot() {
        val u = AccountUnread().record(marker("reply", id = "1", to = bob))
        assertFalse(u.othersHaveUnread(listOf(alice), alice))
    }

    // The badge counts only what the Vault list draws (sweep 11-01 #11).
    private val stranger = "d".repeat(64)
    private val friend = "e".repeat(64)

    private fun shows(
        type: String, author: String, zapsOnly: Boolean = false,
        blocked: Set<String> = emptySet(), outside: Set<String> = emptySet(),
    ): Boolean {
        val m = AccountUnread.parseMarker("type=$type|kind=1|author=$author|id=x|recipient=$alice|preview=hi")!!
        return AccountUnread.listShows(m, zapsOnly, { it in blocked }, { it in outside })
    }

    @Test fun zapsOnlyHidesReactionsButNotZaps() {
        assertFalse(shows("reaction", friend, zapsOnly = true))
        assertTrue(shows("reaction", friend))
        assertTrue(shows("zap", friend, zapsOnly = true))
    }

    @Test fun outsideYourNetworkHidesRepliesQuotesMentionsOnly() {
        for (type in listOf("reply", "quote", "mention")) {
            assertFalse(type, shows(type, stranger, outside = setOf(stranger)))
            assertTrue(type, shows(type, friend, outside = setOf(stranger)))
        }
        // The list keeps these from anyone (VaultActivity.build).
        for (type in listOf("reaction", "repost", "zap", "follow")) {
            assertTrue(type, shows(type, stranger, outside = setOf(stranger)))
        }
    }

    @Test fun blockedAuthorsNeverCount() {
        for (type in listOf("reply", "quote", "mention", "reaction", "repost", "zap", "follow")) {
            assertFalse(type, shows(type, stranger, blocked = setOf(stranger)))
        }
    }

    @Test fun markerCarriesTheAuthorLowercased() {
        val m = AccountUnread.parseMarker("type=zap|kind=9735|author=${"F".repeat(64)}|id=1|recipient=$alice|preview=")
        assertEquals("f".repeat(64), m?.author)
        assertEquals(alice to "1", AccountUnread.parse("type=zap|kind=9735|author=x|id=1|recipient=$alice|preview="))
    }
}
