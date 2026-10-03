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
}
