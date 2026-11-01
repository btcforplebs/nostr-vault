package com.nostrvault.data.model

import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

/**
 * "Notify me when my own accounts tag each other" (off by default): one of
 * your accounts tagging another makes no alert, no count and no Vault tab dot.
 * iOS: OwnAccountTagTests.swift.
 */
class OwnAccountTagTest {
    private val alice = "a".repeat(64)
    private val bob = "b".repeat(64)
    private val carol = "c".repeat(64)
    private val mine = setOf(alice, bob)

    private fun hides(author: String, recipient: String, notify: Boolean = false) =
        AccountUnread.hidesOwnAccountTag(author, recipient, mine, notify)

    @Test fun oneOfMyAccountsTaggingAnotherIsHiddenWhileOff() {
        assertTrue(hides(alice, bob))
        assertTrue(hides(bob, alice))
    }

    @Test fun turningItOnShowsIt() = assertFalse(hides(alice, bob, notify = true))

    @Test fun someoneElseIsNeverHidden() {
        assertFalse(hides(carol, bob))
        assertFalse(hides("", bob))
    }

    @Test fun anAccountTaggingItselfIsLeftToTheRelay() = assertFalse(hides(alice, alice))

    @Test fun aRecipientThatIsNotMineIsNotHidden() {
        assertFalse(hides(alice, carol))
        assertFalse(hides(alice, ""))
    }

    @Test fun caseDoesNotMatter() =
        assertTrue(AccountUnread.hidesOwnAccountTag(alice.uppercase(), bob, setOf(alice, bob.uppercase()), notify = false))

    // Vault tab dot

    private fun marker(type: String, kind: Int, id: String, from: String, to: String) =
        "🔔NOTIFY|type=$type|kind=$kind|author=$from|id=$id|recipient=$to|preview=hi"

    private val rule: (String, String) -> Boolean = { recipient, author -> hides(author, recipient) }

    @Test fun kindOnlyFromMyOwnAccountsIsLeftOut() {
        val kinds = AccountUnread.ownAccountOnlyKinds(
            listOf(marker("mention", 1, "1", alice, bob), marker("reaction", 7, "2", alice, bob)), rule,
        )
        assertEquals(setOf(1, 7), kinds)
    }

    @Test fun kindAlsoFromSomeoneElseStays() {
        val kinds = AccountUnread.ownAccountOnlyKinds(
            listOf(marker("mention", 1, "1", alice, bob), marker("reply", 1, "2", carol, bob)), rule,
        )
        assertEquals(emptySet<Int>(), kinds)
    }

    @Test fun markerWithoutThePrefixParsesToo() {
        val kinds = AccountUnread.ownAccountOnlyKinds(
            listOf("type=mention|kind=1|author=$alice|id=1|recipient=$bob|preview=a|kind=7"), rule,
        )
        assertEquals(setOf(1), kinds)
    }

    @Test fun nothingLeftOutWhenTheSwitchIsOn() {
        val kinds = AccountUnread.ownAccountOnlyKinds(listOf(marker("mention", 1, "1", alice, bob))) { r, a ->
            AccountUnread.hidesOwnAccountTag(a, r, mine, notify = true)
        }
        assertEquals(emptySet<Int>(), kinds)
    }
}
