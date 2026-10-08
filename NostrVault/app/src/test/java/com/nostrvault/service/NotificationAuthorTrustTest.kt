package com.nostrvault.service

import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

class NotificationAuthorTrustTest {
    private val trusted = setOf("friend")

    @Test
    fun `only trusted authors notify`() {
        assertTrue(LocalNotificationService.authorMayNotify("friend", "reply", trusted, emptySet()))
        assertFalse(LocalNotificationService.authorMayNotify("stranger", "reply", trusted, emptySet()))
        assertFalse(LocalNotificationService.authorMayNotify("stranger", "mention", trusted, emptySet()))
        assertFalse(LocalNotificationService.authorMayNotify("stranger", "dm", trusted, emptySet()))
        assertFalse(LocalNotificationService.authorMayNotify("stranger", "reaction", trusted, emptySet()))
    }

    @Test
    fun `graph not loaded, own events, gift wraps, summary and zaps are not held back`() {
        assertTrue(LocalNotificationService.authorMayNotify("stranger", "reply", emptySet(), emptySet()))
        assertTrue(LocalNotificationService.authorMayNotify("me", "repost", trusted, setOf("me")))
        assertTrue(LocalNotificationService.authorMayNotify("throwaway", "giftwrap", trusted, emptySet()))
        assertTrue(LocalNotificationService.authorMayNotify("", "summary", trusted, emptySet()))
        // A zap marker names the lightning service; the relay judged the zapper.
        assertTrue(LocalNotificationService.authorMayNotify("lnservice", "zap", trusted, emptySet()))
    }

    @Test
    fun `follows are never dropped for trust, only strangers go unnamed`() {
        assertTrue(LocalNotificationService.authorMayNotify("stranger", "follow", trusted, emptySet()))
        assertTrue(LocalNotificationService.authorMayNotify("stranger", "follow", emptySet(), emptySet()))
        assertTrue(LocalNotificationService.followIsNamed("friend", trusted))
        assertFalse(LocalNotificationService.followIsNamed("stranger", trusted))
        // A new account has no graph yet: nobody is named.
        assertFalse(LocalNotificationService.followIsNamed("friend", emptySet()))
    }

    @Test
    fun `the folded alert counts each stranger once and starts over when cleared`() {
        val empty = LocalNotificationService.FoldedFollowers()
        assertFalse(empty.isShowing)
        var showing = LocalNotificationService.foldedFollowers(empty, "a")
        assertTrue(showing.isShowing)
        showing = LocalNotificationService.foldedFollowers(showing, "b")
        showing = LocalNotificationService.foldedFollowers(showing, "a")
        assertEquals(LocalNotificationService.FoldedFollowers(listOf("b", "a"), 2), showing)
        assertEquals(LocalNotificationService.FoldedFollowers(listOf("c"), 1), LocalNotificationService.foldedFollowers(empty, "c"))
        assertEquals("New follower", LocalNotificationService.foldedFollowersText(1).first)
        assertEquals("3 new followers", LocalNotificationService.foldedFollowersText(3).first)
    }

    @Test
    fun `the folded alert keeps counting past the strangers it carries`() {
        var showing = LocalNotificationService.FoldedFollowers()
        repeat(1000) { showing = LocalNotificationService.foldedFollowers(showing, "k$it") }
        assertEquals(1000, showing.count)
        assertEquals(32, showing.members.size)
        assertEquals("k999", showing.members.last())
    }

    @Test
    fun `a follower key must be 64 hex characters`() {
        assertTrue(LocalNotificationService.isPubkeyHex("ab".repeat(32)))
        assertFalse(LocalNotificationService.isPubkeyHex(""))
        assertFalse(LocalNotificationService.isPubkeyHex("zz".repeat(32)))
    }
}
