package com.nostrvault.service

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
}
