package com.nostrvault.service

import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

/**
 * An arrival pill that goes unread is filed in the tray; one that was read or
 * tapped takes its tray entry with it. Each banner ends once. iOS
 * `NotificationPolicy.filesPill` and `RelayActivityNotificationManager`.
 */
class InAppBannersTest {

    private fun banner(id: String, type: String = "dm") =
        InAppBanner(id, "Message from Alice", "meet at 6", type, "author", "npub1x")

    /** Banners wired to a tray the way LocalNotificationService wires them. */
    private class Rig(drawn: Map<String, Long> = emptyMap()) {
        val ends = mutableListOf<Pair<String, Boolean>>()
        val tray = LinkedHashMap<String, String>()
        private val system = object : NotificationTray.Platform<String> {
            override fun notify(tag: String, id: Int, notification: String) { tray[tag] = notification }
            override fun cancel(tag: String, id: Int) { tray.remove(tag) }
        }
        private val trayEntries = NotificationTray(system)
        val banners = InAppBanners { laneId -> drawn[laneId] ?: 0L }.apply {
            onEnd = { b, read ->
                ends += b.id to read
                if (read) trayEntries.markRead(b.id)
                else trayEntries.post(b.id, InAppBanners.filedTitle(b.type, b.title), filedPill = true)
            }
            onShow = { b -> trayEntries.unread(b.id) }
        }
        var foreground = true
        /** As LocalNotificationService.deliver: the pill in front, the tray (a real alert) behind. */
        fun deliver(b: InAppBanner) =
            banners.deliver(b, { foreground }) { trayEntries.post(it.id, "alert: ${it.title}") }
    }

    @Test fun aTrimmedUnreadPillIsFiledQuietly() {
        val rig = Rig()
        rig.banners.show(banner("a"))
        rig.banners.show(banner("b"))
        assertEquals(listOf("a" to false), rig.ends)
        // A DM files with the generic title: the sender stays in the app.
        assertEquals(mapOf("a" to InAppBanners.DM_FILED_TITLE), rig.tray)
        assertEquals("b", rig.banners.current.value?.id)
    }

    @Test fun aPillThatOnlyFlashedIsFiledAndOneReadLongEnoughIsNot() {
        val rig = Rig(mapOf("activity:short" to 400L, "activity:long" to 3_000L))
        rig.banners.show(banner("short", type = "mention"))
        rig.banners.dismiss("short", PillEnd.TIMED_OUT)
        rig.banners.show(banner("long", type = "mention"))
        rig.banners.dismiss("long", PillEnd.TIMED_OUT)
        assertEquals(listOf("short" to false, "long" to true), rig.ends)
        assertEquals(mapOf("short" to "Message from Alice"), rig.tray)
    }

    @Test fun aTappedPillIsReadAndTakesItsTrayEntry() {
        val rig = Rig()
        rig.tray["a"] = "already filed"
        rig.banners.show(banner("a"))
        rig.banners.dismiss("a", PillEnd.TAPPED)
        assertEquals(listOf("a" to true), rig.ends)
        assertTrue(rig.tray.isEmpty())
    }

    @Test fun goingToTheBackgroundFilesTheUnreadPill() {
        val rig = Rig()
        rig.banners.show(banner("a"))
        rig.banners.hostLost()
        assertEquals(listOf("a" to false), rig.ends)
        assertNull(rig.banners.current.value)
    }

    @Test fun trimThenTapThenTimerEndThePillOnce() {
        // The order Tron flagged: trimmed (filed), then a late tap and a late
        // timer for the same pill. Neither may cancel or post again.
        val rig = Rig()
        rig.banners.show(banner("a"))
        rig.banners.show(banner("b"))
        rig.banners.dismiss("a", PillEnd.TAPPED)
        rig.banners.dismiss("a", PillEnd.TIMED_OUT)
        assertEquals(listOf("a" to false), rig.ends)
        assertEquals(setOf("a"), rig.tray.keys)
        // The newer banner is untouched by the old one's timer.
        assertEquals("b", rig.banners.current.value?.id)
    }

    @Test fun readThenALateTrimPostsNothing() {
        val rig = Rig()
        rig.banners.show(banner("a"))
        rig.banners.dismiss("a", PillEnd.TAPPED)
        rig.banners.show(banner("b"))
        rig.banners.hostLost()
        assertEquals(listOf("a" to true, "b" to false), rig.ends)
        assertEquals(setOf("b"), rig.tray.keys)
    }

    @Test fun aNonDmKindInTheForegroundBecomesAPillNotATrayPost() {
        val rig = Rig(mapOf("activity:m" to 3_000L))
        for (type in listOf("mention", "reply", "quote", "zap", "reaction", "repost", "follow", "followers")) {
            rig.deliver(banner("m", type))
            assertEquals(type, "m", rig.banners.current.value?.id)
            assertTrue(type, rig.tray.isEmpty())
            // Read on screen: still nothing in the tray.
            rig.banners.dismiss("m", PillEnd.TIMED_OUT)
            assertTrue(type, rig.tray.isEmpty())
        }
    }

    @Test fun aNonDmKindInTheBackgroundGoesToTheTrayAndDrawsNoPill() {
        val rig = Rig()
        rig.foreground = false
        rig.deliver(banner("m", "mention"))
        assertNull(rig.banners.current.value)
        assertEquals(mapOf("m" to "alert: Message from Alice"), rig.tray)
        assertTrue(rig.ends.isEmpty())
    }

    @Test fun aMentionPillLeftUnreadIsFiledWithItsOwnText() {
        val rig = Rig()
        rig.deliver(banner("m", "mention"))
        rig.deliver(banner("n", "reply"))
        // The mention keeps its title; only a DM is reduced to the generic line.
        assertEquals(mapOf("m" to "Message from Alice"), rig.tray)
    }

    @Test fun anIdThatComesBackIsFiledAgainAfterARead() {
        // The folded followers' alert and a returning named follower reuse their id.
        val rig = Rig()
        rig.deliver(banner("followers-npub1x", "followers"))
        rig.banners.dismiss("followers-npub1x", PillEnd.TAPPED)
        rig.deliver(banner("followers-npub1x", "followers"))
        rig.banners.hostLost()
        assertEquals(setOf("followers-npub1x"), rig.tray.keys)
    }

    @Test fun theRule() {
        assertTrue(InAppBanners.filesPill(PillEnd.TRIMMED, 0))
        assertTrue(InAppBanners.filesPill(PillEnd.HOST_LOST, InAppBanners.READABLE_AFTER_MS - 1))
        assertEquals(false, InAppBanners.filesPill(PillEnd.TIMED_OUT, InAppBanners.READABLE_AFTER_MS))
        assertEquals(false, InAppBanners.filesPill(PillEnd.TAPPED, 0))
        assertEquals("Alice mentioned you", InAppBanners.filedTitle("mention", "Alice mentioned you"))
        assertEquals(InAppBanners.DM_FILED_TEXT, InAppBanners.filedText("giftwrap", "meet at 6"))
    }
}
