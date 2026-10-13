package com.nostrvault.ui.screens.profile

import com.nostrvault.ui.screens.profile.ProfileEmptyTabPaging.Status
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

class ProfileEmptyTabPagingTest {

    /**
     * A profile whose newest pages hold no replies. The Replies tab pages back
     * on its own, one page per finished page, stops after the cap, and then
     * offers "Look further back" rather than "No replies yet".
     */
    @Test fun emptyTabPagesBackUpToTheCapThenOffersToLookFurther() {
        val paging = ProfileEmptyTabPaging()
        var pages = 0
        // Each finished page re-asks, as the screen's effect does.
        while (pages < 100 && paging.claim(ProfileSection.REPLIES, isEmpty = true, canPageOlder = true, isLoadingOlder = false)) pages++
        assertEquals(ProfileEmptyTabPaging.AUTO_PAGE_CAP, pages)
        assertEquals(Status.OLDER_LEFT, ProfileEmptyTabPaging.status(opening = false, pagingNow = false, canPageOlder = true))
    }

    @Test fun aPageThatFindsSomeStopsThePaging() {
        val paging = ProfileEmptyTabPaging()
        assertTrue(paging.claim(ProfileSection.REPLIES, isEmpty = true, canPageOlder = true, isLoadingOlder = false))
        assertFalse(paging.claim(ProfileSection.REPLIES, isEmpty = false, canPageOlder = true, isLoadingOlder = false))
    }

    @Test fun waitsForAPageInFlightThenTakesItsTurn() {
        val paging = ProfileEmptyTabPaging()
        // Another tab's page is loading: no page now, and none spent.
        assertFalse(paging.claim(ProfileSection.REPOSTS, isEmpty = true, canPageOlder = true, isLoadingOlder = true))
        repeat(ProfileEmptyTabPaging.AUTO_PAGE_CAP) {
            assertTrue(paging.claim(ProfileSection.REPOSTS, isEmpty = true, canPageOlder = true, isLoadingOlder = false))
        }
    }

    @Test fun nothingOlderOrNoAnchorMeansNoPageAndNoneYet() {
        val paging = ProfileEmptyTabPaging()
        assertFalse(paging.claim(ProfileSection.MEDIA, isEmpty = true, canPageOlder = false, isLoadingOlder = false))
        assertEquals(Status.NONE, ProfileEmptyTabPaging.status(opening = false, pagingNow = false, canPageOlder = false))
    }

    @Test fun eachTabHasItsOwnPagesAndANewProfileResetsThem() {
        val paging = ProfileEmptyTabPaging(cap = 2)
        repeat(2) { assertTrue(paging.claim(ProfileSection.REPLIES, true, true, false)) }
        assertFalse(paging.claim(ProfileSection.REPLIES, true, true, false))
        assertTrue(paging.claim(ProfileSection.TAGGED, true, true, false))
        paging.reset()
        assertTrue(paging.claim(ProfileSection.REPLIES, true, true, false))
    }

    @Test fun loadingWinsOverEverythingElse() {
        assertEquals(Status.LOADING, ProfileEmptyTabPaging.status(opening = true, pagingNow = false, canPageOlder = true))
        assertEquals(Status.LOADING, ProfileEmptyTabPaging.status(opening = false, pagingNow = true, canPageOlder = false))
    }
}
