package com.nostrvault.widget

import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

/** Mirrors the iOS NVFeedLayout tests in HavenApp/MediaLogicTests. */
class FeedWidgetLogicTest {

    private fun plan(height: Float, rowHeight: Float = 45f, notes: Int = 10) =
        FeedLayout.plan(height, headerHeight = 26f, rowHeight = rowHeight, minSpacing = 6f, maxSpacing = 18f, noteCount = notes)

    @Test
    fun rowsNeverOverflowTheHeight() {
        for (h in listOf(80f, 120f, 160f, 300f, 500f)) {
            val p = plan(h)
            val used = 26f + p.rows * 45f + (p.rows - 1) * p.spacing
            assertTrue("height $h used $used", p.rows == 1 || used <= h + 0.01f)
        }
    }

    @Test
    fun alwaysDrawsAtLeastOneRow() {
        assertEquals(1, plan(10f).rows)
    }

    @Test
    fun fewNotesInATallWidgetCapTheSpacing() {
        val p = plan(600f, notes = 3)
        assertEquals(3, p.rows)
        assertEquals(18f, p.spacing, 0.001f)
    }

    @Test
    fun compactRowsFitMore() {
        assertTrue(plan(300f, rowHeight = 30f).rows > plan(300f, rowHeight = 45f).rows)
    }

    @Test
    fun noNotesNoRows() {
        assertEquals(0, plan(300f, notes = 0).rows)
    }

    @Test
    fun shortAgeBuckets() {
        val now = 1_000_000_000L
        assertEquals("now", shortAge(now - 30_000, now))
        assertEquals("5m", shortAge(now - 5 * 60_000, now))
        assertEquals("3h", shortAge(now - 3 * 3_600_000, now))
        assertEquals("2d", shortAge(now - 2 * 86_400_000, now))
        // A clock that ran ahead is "now", not a negative age.
        assertEquals("now", shortAge(now + 60_000, now))
    }

    @Test
    fun mentionIsAPTagFromSomeoneElse() {
        val me = "a".repeat(64)
        val other = "b".repeat(64)
        assertTrue(isMentionOf(me, other, listOf(listOf("p", me))))
        assertFalse(isMentionOf(me, me, listOf(listOf("p", me))))
        assertFalse(isMentionOf(me, other, listOf(listOf("e", me))))
        assertFalse(isMentionOf("", other, listOf(listOf("p", ""))))
    }
}
