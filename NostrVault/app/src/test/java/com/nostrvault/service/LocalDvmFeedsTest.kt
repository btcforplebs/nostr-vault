package com.nostrvault.service

import com.nostrvault.data.model.FeedMode
import com.nostrvault.data.model.FeedThreadReplies
import com.nostrvault.data.model.isLocalDvm
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test
import com.nostrvault.data.model.FeedNote
import java.util.Date

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

    /** Logen 2026-11-06: Underrated is only people you don't follow. */
    @Test
    fun `Underrated leaves out people the active account follows`() {
        fun note(id: String, pubkey: String) =
            FeedNote(id = id, pubkey = pubkey, content = "hello", createdAt = Date(1_700_000_000_000L), tags = emptyList(), kind = 1)
        val shown = FeedFilterEngine.filterFeedNotes(
            notes = listOf(note("followed", a), note("out", b)),
            mode = FeedMode.UNDERRATED,
            blocked = emptySet(),
            showReposts = true,
            showReplies = true,
            followedPubkeys = setOf(a),
            wotPubkeys = setOf(a, b),
        )
        assertEquals(listOf("out"), shown.map { it.id })
    }
}
