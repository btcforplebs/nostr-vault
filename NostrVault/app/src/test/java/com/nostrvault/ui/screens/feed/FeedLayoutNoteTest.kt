package com.nostrvault.ui.screens.feed

import com.nostrvault.data.model.FeedLayoutMode
import com.nostrvault.ui.theme.NostrVaultIcons
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Test

/**
 * The pill the feed's layout button leaves, word for word as the iPhone's
 * toolbar note (iOS `FeedToolbarState.note(changedFrom:)`, layout case).
 */
class FeedLayoutNoteTest {

    @Test
    fun `switching to threaded names the layout and the replies it turned on`() {
        val note = feedLayoutNote(FeedLayoutSwitch(FeedLayoutMode.THREADED, repliesShown = true))
        assertEquals("Layout · Threaded, replies shown", note.text)
        assertEquals(NostrVaultIcons.ThreadedView, note.icon)
        assertFalse(note.dimmed)
    }

    @Test
    fun `switching to expanded names the layout and the replies it turned off`() {
        val note = feedLayoutNote(FeedLayoutSwitch(FeedLayoutMode.EXPANDED, repliesShown = false))
        assertEquals("Layout · Expanded, replies hidden", note.text)
        assertEquals(NostrVaultIcons.ExpandedView, note.icon)
    }

    @Test
    fun `when replies were already right only the layout is named`() {
        assertEquals("Layout · Threaded", feedLayoutNote(FeedLayoutSwitch(FeedLayoutMode.THREADED, repliesShown = null)).text)
        assertEquals("Layout · Expanded", feedLayoutNote(FeedLayoutSwitch(FeedLayoutMode.EXPANDED, repliesShown = null)).text)
    }

}
