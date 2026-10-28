package com.nostrvault.ui.screens.feed

import com.nostrvault.data.model.FeedNote
import com.nostrvault.data.model.FeedThread
import com.nostrvault.data.model.FeedThreadEntry
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Test
import java.util.Date

/** Which row shows the open post: what auto-apply and the tap-line room watch (PR #1282 review). */
class FeedOpenRowKeyTest {
    private fun note(id: String) = FeedNote(
        id = id, pubkey = "alice", content = "", createdAt = Date(0), tags = emptyList(), kind = 1,
        repostedBy = null, isReply = false, replyToPubkey = null, parentEventId = null,
        mediaURLs = emptyList(), linkURLs = emptyList(), quotedEventIds = emptyList(), repostedEventId = null,
    )
    private val threads = listOf(
        FeedThread(rootId = "r", root = note("r"), entries = listOf(FeedThreadEntry(note("r"), 0), FeedThreadEntry(note("r1"), 1)), latestActivity = Date(0)),
        FeedThread(rootId = "t", root = null, entries = listOf(FeedThreadEntry(note("t1"), 1)), latestActivity = Date(0)),
    )

    @Test fun nothingOpenHasNoRow() = assertNull(openRowKey(null, isThreaded = true, threads))

    @Test fun condensedRowsAreKeyedByThePost() = assertEquals("r1", openRowKey("r1", isThreaded = false, threads))

    @Test fun aThreadedPostIsShownByItsThreadCard() {
        assertEquals("r", openRowKey("r1", isThreaded = true, threads))
        assertEquals("r", openRowKey("r", isThreaded = true, threads))
        assertEquals("t", openRowKey("t1", isThreaded = true, threads))
    }

    @Test fun aPostNoLongerInTheFeedHasNoRow() = assertNull(openRowKey("gone", isThreaded = true, threads))
}
