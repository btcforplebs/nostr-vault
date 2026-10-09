package com.nostrvault.service

import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

class InAppDmAlertTest {
    /** Phone notifications off: a DM still gets the in-app banner while the app is open, nothing else does. */
    @Test fun `push off allows only foreground DMs`() {
        assertTrue(LocalNotificationService.allowsWithPushOff("giftwrap", appInForeground = true))
        assertTrue(LocalNotificationService.allowsWithPushOff("dm", appInForeground = true))
        assertFalse(LocalNotificationService.allowsWithPushOff("giftwrap", appInForeground = false))
        for (type in listOf("mention", "reply", "zap", "reaction", "repost", "summary")) {
            assertFalse(type, LocalNotificationService.allowsWithPushOff(type, appInForeground = true))
        }
    }

    /** An older banner's timer must not hide a newer one. */
    @Test fun `dismissing a stale banner keeps the current one`() {
        val first = InAppBanner("a", "t", "x", "giftwrap", "", "")
        val second = first.copy(id = "b")
        InAppBannerBus.show(first)
        InAppBannerBus.show(second)
        InAppBannerBus.dismiss("a")
        assertEquals(second, InAppBannerBus.current.value)
        InAppBannerBus.dismiss("b")
        assertNull(InAppBannerBus.current.value)
    }

    /** A decrypted DM becomes one readable line; nothing to read keeps the generic one. */
    @Test fun `dm preview is one line and cut to the limit`() {
        assertEquals("hey are you around?", LocalNotificationService.dmPreview("hey\n\n  are you  around?\t"))
        assertNull(LocalNotificationService.dmPreview(" \n\t "))
        val preview = LocalNotificationService.dmPreview("a".repeat(300), limit = 160)
        assertEquals(160, preview?.length)
        assertTrue(preview!!.endsWith("…"))
        assertEquals(160, LocalNotificationService.dmPreview("b".repeat(160), limit = 160)?.length)
    }
}
