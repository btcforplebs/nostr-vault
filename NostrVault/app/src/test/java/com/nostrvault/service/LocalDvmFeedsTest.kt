package com.nostrvault.service

import com.nostrvault.data.model.FeedMode
import com.nostrvault.data.model.FeedThreadReplies
import com.nostrvault.data.model.isLocalDvm
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

/** Popular, Catch Up and Underrated: computed by the relay's local DVM (iOS FeedMode.isLocalDvm). */
class LocalDvmFeedsTest {
    private val a = "a".repeat(64)
    private val b = "b".repeat(64)

    @Test
    fun `exactly the three DVM feeds are local DVM feeds`() {
        assertEquals(
            setOf(FeedMode.POPULAR, FeedMode.CATCH_UP, FeedMode.UNDERRATED),
            FeedMode.entries.filter { it.isLocalDvm }.toSet(),
        )
    }

    @Test
    fun `the new feeds sit right after Popular in the picker`() {
        val order = FeedMode.entries
        val popular = order.indexOf(FeedMode.POPULAR)
        assertEquals(FeedMode.CATCH_UP, order[popular + 1])
        assertEquals(FeedMode.UNDERRATED, order[popular + 2])
        assertEquals("Catch Up", FeedMode.CATCH_UP.displayName)
        assertEquals("Underrated", FeedMode.UNDERRATED.displayName)
    }

    @Test
    fun `local DVM feeds are cached and threaded but never prewarmed`() {
        for (mode in listOf(FeedMode.CATCH_UP, FeedMode.UNDERRATED)) {
            assertTrue(FeedModeCaches.usesNotePipeline(mode))
            assertTrue(mode in FeedModeCacheDisk.MODES)
            assertTrue(FeedThreadReplies.fetchesReplies(mode))
            assertFalse(shouldPrewarm(mode, notesEmpty = true, restored = false, loadStarted = false))
        }
    }

    @Test
    fun `the follow list goes to the relay as clean lowercase hex`() {
        assertEquals(
            "[\"$a\",\"$b\"]",
            LocalDvmFeeds.followsJson(listOf(a.uppercase(), " $a ", "npub1xyz", "", b)),
        )
        assertEquals("[]", LocalDvmFeeds.followsJson(emptyList()))
    }

    @Test
    fun `empty statuses say why`() {
        assertEquals("Follow people to catch up with them", LocalDvmFeeds.emptyStatus(FeedMode.CATCH_UP, graphReady = false, followsNobody = true))
        assertEquals("Nobody you follow posted lately", LocalDvmFeeds.emptyStatus(FeedMode.CATCH_UP, graphReady = false, followsNobody = false))
        assertEquals("No underrated notes", LocalDvmFeeds.emptyStatus(FeedMode.UNDERRATED, graphReady = true, followsNobody = false))
        assertEquals("Building your web of trust…", LocalDvmFeeds.emptyStatus(FeedMode.UNDERRATED, graphReady = false, followsNobody = false))
        assertEquals("No popular notes", LocalDvmFeeds.emptyStatus(FeedMode.POPULAR, graphReady = true, followsNobody = false))
    }
}
