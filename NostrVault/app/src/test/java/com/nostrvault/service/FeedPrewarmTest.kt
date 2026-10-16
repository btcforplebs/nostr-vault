package com.nostrvault.service

import com.nostrvault.data.model.FeedMode
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

/** The cached feed shows before the relay is up, then still gets its first load (iOS prewarmFromCache). */
class FeedPrewarmTest {

    @Test
    fun `a fresh launch prewarms`() {
        assertTrue(shouldPrewarm(FeedMode.FOLLOWING, notesEmpty = true, restored = false, loadStarted = false))
    }

    @Test
    fun `no prewarm for Popular, a feed already showing, or after it ran or the load began`() {
        assertFalse(shouldPrewarm(FeedMode.POPULAR, notesEmpty = true, restored = false, loadStarted = false))
        assertFalse(shouldPrewarm(FeedMode.FOLLOWING, notesEmpty = false, restored = false, loadStarted = false))
        assertFalse(shouldPrewarm(FeedMode.FOLLOWING, notesEmpty = true, restored = true, loadStarted = false))
        assertFalse(shouldPrewarm(FeedMode.FOLLOWING, notesEmpty = true, restored = false, loadStarted = true))
    }

    /** The bug this guards: the readiness check skipped any feed with notes, so a prewarmed one never topped up. */
    @Test
    fun `a prewarmed feed still starts its load when the relay is ready`() {
        assertTrue(shouldStartInitialLoad(notesEmpty = false, restored = true, loadStarted = false))
    }

    @Test
    fun `an empty feed loads, as before`() {
        assertTrue(shouldStartInitialLoad(notesEmpty = true, restored = false, loadStarted = false))
        assertTrue(shouldStartInitialLoad(notesEmpty = true, restored = false, loadStarted = true))
    }

    @Test
    fun `a feed with notes and its load under way is left alone`() {
        assertFalse(shouldStartInitialLoad(notesEmpty = false, restored = true, loadStarted = true))
        assertFalse(shouldStartInitialLoad(notesEmpty = false, restored = false, loadStarted = false))
    }
}
