package com.nostrvault.service

import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

/** One tray entry per event: a read pill takes its entry, an unread one files quietly, and ids never collide. */
class NotificationTrayTest {

    /** The tray as Android keys it: by (tag, id). */
    private class FakeTray : NotificationTray.Platform<String> {
        val posted = LinkedHashMap<Pair<String, Int>, String>()
        override fun notify(tag: String, id: Int, notification: String) { posted[tag to id] = notification }
        override fun cancel(tag: String, id: Int) { posted.remove(tag to id) }
        val shown: List<String> get() = posted.values.toList()
    }

    @Test fun twoIdsThatHashAlikeKeepTheirOwnEntries() {
        // The gate: "Aa" and "BB" share a 32-bit hashCode, as two event ids can.
        assertEquals("Aa".hashCode(), "BB".hashCode())
        val system = FakeTray()
        val tray = NotificationTray(system)
        tray.post("Aa", "alice")
        tray.post("BB", "bob")
        assertEquals(listOf("alice", "bob"), system.shown)

        // Reading one pill clears its entry, not the other unread one.
        tray.markRead("Aa")
        assertEquals(listOf("bob"), system.shown)
    }

    @Test fun twoIdsThatHashAlikeOpenTheirOwnEvent() {
        // The tap intents share a component and a request code ("Aa".hashCode()
        // == "BB".hashCode()), carry no action, type or category, and extras
        // don't count, so the data URI is the only part of Intent.filterEquals
        // left to tell them apart. Equal data would let FLAG_UPDATE_CURRENT
        // point both entries at the second event.
        assertEquals("Aa".hashCode(), "BB".hashCode())
        assertTrue(NotificationTray.tapUri("Aa") != NotificationTray.tapUri("BB"))
        // Any id survives as a valid, distinct URI path.
        assertTrue(NotificationTray.tapUri("a/b c") != NotificationTray.tapUri("a/b+c"))
        assertEquals("nostrvault://notification/a%2Fb+c", NotificationTray.tapUri("a/b c"))
    }

    @Test fun readingAPillRemovesItsEntry() {
        val system = FakeTray()
        val tray = NotificationTray(system)
        tray.post("e1", "filed", filedPill = true)
        tray.markRead("e1")
        assertTrue(system.shown.isEmpty())
    }

    @Test fun aFilingThatLandsAfterTheReadPostsNothing() {
        val system = FakeTray()
        val tray = NotificationTray(system)
        tray.markRead("e1")
        assertFalse(tray.post("e1", "filed late", filedPill = true))
        assertTrue(system.shown.isEmpty())
    }

    @Test fun aReadEventStillTakesARealAlert() {
        // Only the pill's quiet filing is held back; a fresh alert for the
        // event (none today, but nothing should swallow one) still posts.
        val system = FakeTray()
        val tray = NotificationTray(system)
        tray.markRead("e1")
        assertTrue(tray.post("e1", "alert"))
        assertEquals(listOf("alert"), system.shown)
    }
}
