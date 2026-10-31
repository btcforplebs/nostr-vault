package com.nostrvault.data.model

import org.junit.Assert.assertEquals
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
}
