package com.nostrvault.ui.navigation

import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

/** Where scrolling folds the bottom bar: where the iPhone's lists call scrollDirectionTracking. */
class ChromeFoldRoutesTest {

    @Test
    fun `the iPhone's folding screens fold`() {
        for (route in listOf(
            Screen.Feed.route,
            Screen.Dashboard.route,
            Screen.Search.route,
            PROFILE_TAB_ROUTE,
            Screen.Profile.route,
            Screen.ArticleReader.route,
        )) {
            assertTrue(route, foldsChromeOnScroll(route))
        }
    }

    @Test
    fun `the rest keep the bar shown`() {
        for (route in listOf(Screen.WOT.route, Screen.NoteDetail.route, Screen.MediaSettings.route, null)) {
            assertFalse(route.toString(), foldsChromeOnScroll(route))
        }
    }
}
