package com.nostrvault.ui.screens.dm

import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

/** A new message only scrolls the open chat from the bottom, or when you sent it (Messages check A3). */
class DMThreadFollowTest {
    @Test
    fun `reading older messages, an incoming one does not pull you down`() {
        assertFalse(DMThreadFollow.followsNewest(wasAtBottom = false, newestIsMine = false))
    }

    @Test
    fun `at the bottom, an incoming one is followed`() {
        assertTrue(DMThreadFollow.followsNewest(wasAtBottom = true, newestIsMine = false))
    }

    @Test
    fun `your own send is always shown`() {
        assertTrue(DMThreadFollow.followsNewest(wasAtBottom = false, newestIsMine = true))
    }
}
