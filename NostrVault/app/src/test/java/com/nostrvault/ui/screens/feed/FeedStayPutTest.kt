package com.nostrvault.ui.screens.feed

import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test
import java.io.File

/** The Feed never moves the reader on its own (Logen 2026-11-04; iOS FeedStayPutTests). */
class FeedStayPutTest {
    @Test fun `auto-load goes in wherever the reader is`() {
        assertTrue(FeedStayPut.autoLoads(enabled = true, waiting = 3, isLoading = false, postOpen = false))
        assertFalse(FeedStayPut.autoLoads(enabled = false, waiting = 3, isLoading = false, postOpen = false))
        assertFalse(FeedStayPut.autoLoads(enabled = true, waiting = 0, isLoading = false, postOpen = false))
        assertFalse("not during a load", FeedStayPut.autoLoads(enabled = true, waiting = 3, isLoading = true, postOpen = false))
        assertFalse("not over a tapped post", FeedStayPut.autoLoads(enabled = true, waiting = 3, isLoading = false, postOpen = true))
    }

    @Test fun `below the top the row being read is held`() {
        assertFalse(FeedStayPut.keepsReading(isAtTop = true))
        assertTrue(FeedStayPut.keepsReading(isAtTop = false))
    }

    @Test fun `the held row moves down by what went in above`() {
        val before = listOf("d", "e", "f", "g")
        val after = listOf("a", "b", "c") + before
        // Reading "f" at index 2: three posts went in, so it is now at 5.
        assertEquals(5, FeedStayPut.heldIndex(after, "f", oldIndex = 2))
        assertNull("not moved", FeedStayPut.heldIndex(before, "f", oldIndex = 2))
        assertNull("left the list", FeedStayPut.heldIndex(listOf("x", "y"), "f", oldIndex = 2))
    }

    @Test fun `new above counts the rows over the reader since the top they saw`() {
        val keys = listOf("n1", "n2", "n3", "old1", "old2", "old3", "old4")
        // Saw old1 at the top, three went in, reading old3 (index 5).
        assertEquals(3, FeedStayPut.newAbove(keys, seenTop = "old1", firstVisible = 5))
        // Scrolled up to n3 (index 2): two left above.
        assertEquals(2, FeedStayPut.newAbove(keys, seenTop = "old1", firstVisible = 2))
        assertEquals(0, FeedStayPut.newAbove(keys, seenTop = "old1", firstVisible = 0))
        assertEquals("nothing new", 0, FeedStayPut.newAbove(keys, seenTop = "n1", firstVisible = 5))
        assertEquals("a reload starts over", 0, FeedStayPut.newAbove(keys, seenTop = "gone", firstVisible = 5))
        assertEquals(0, FeedStayPut.newAbove(keys, seenTop = null, firstVisible = 5))
        assertEquals("3 new above", FeedStayPut.aboveLabel(3))
    }

    @Test fun `auto-apply no longer waits for the top`() {
        val src = File("src/main/java/com/nostrvault/ui/screens/feed/FeedScreenEffects.kt").readText()
            .substringAfter("internal fun FeedAutoApplyEffect(").substringBefore("internal suspend fun LazyListState.applyHoldingReadRow")
        assertFalse(src.contains("autoLoad() && isAtTop()"))
        assertTrue(src.contains("applyHoldingReadRow"))
    }
}
