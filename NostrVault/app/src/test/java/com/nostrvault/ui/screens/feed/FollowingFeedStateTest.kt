package com.nostrvault.ui.screens.feed

import com.nostrvault.ui.screens.feed.FollowingFeedPlaceholder.EMPTY
import com.nostrvault.ui.screens.feed.FollowingFeedPlaceholder.FEED
import com.nostrvault.ui.screens.feed.FollowingFeedPlaceholder.LOADING
import org.junit.Assert.assertEquals
import org.junit.Test

/** The same cases as iOS FollowingFeedStateTests. */
class FollowingFeedStateTest {

    private fun decide(
        follows: Int = 0,
        attempted: Boolean = false,
        loadingContacts: Boolean = false,
        loadingFeed: Boolean = false,
        hasNotes: Boolean = false,
    ) = followingFeedPlaceholder(follows, attempted, loadingContacts, loadingFeed, hasNotes)

    @Test
    fun aColdLaunchBeforeAnythingStartedIsLoadingNotEmpty() {
        assertEquals(LOADING, decide())
    }

    @Test
    fun aFinishedLoadWithNoFollowsIsEmpty() {
        assertEquals(EMPTY, decide(attempted = true))
    }

    @Test
    fun loadingContactsOrNotesIsLoading() {
        assertEquals(LOADING, decide(attempted = true, loadingContacts = true))
        assertEquals(LOADING, decide(follows = 12, attempted = true, loadingFeed = true))
    }

    @Test
    fun aBackupSeededFollowSetIsStillLoadingUntilTheLoadEnds() {
        assertEquals(LOADING, decide(follows = 40))
        assertEquals(FEED, decide(follows = 40, attempted = true))
    }

    @Test
    fun notesOnScreenAlwaysWin() {
        assertEquals(FEED, decide(hasNotes = true))
        assertEquals(FEED, decide(attempted = true, loadingContacts = true, hasNotes = true))
    }
}
