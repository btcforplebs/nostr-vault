package com.nostrvault.ui.navigation

import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

/** Feed and Vault taps step back as iOS tabs do: a note opened from the tab
 *  keeps it lit, a tap goes back to it, the next scrolls to the top. */
class TabTapStepsTest {
    private val feed = Screen.Feed.route
    private val vault = Screen.Dashboard.route
    private val note = Screen.NoteDetail.route
    private val profile = Screen.Profile.route

    @Test fun aTabOnScreenIsLit() {
        assertEquals(feed, selectedTabRoute(listOf(null, feed)))
        assertEquals(vault, selectedTabRoute(listOf(null, feed, vault)))
    }

    @Test fun aNoteKeepsItsTabLit() {
        assertEquals(feed, selectedTabRoute(listOf(null, feed, note)))
        assertEquals(feed, selectedTabRoute(listOf(null, feed, note, profile, note)))
        assertEquals(vault, selectedTabRoute(listOf(null, feed, vault, note)))
    }

    @Test fun otherTabsKeepTheirPushedScreensUnlit() {
        // A note opened from Search or your profile lights nothing, as before.
        assertEquals(note, selectedTabRoute(listOf(null, feed, Screen.Search.route, note)))
        assertEquals(note, selectedTabRoute(listOf(null, feed, PROFILE_TAB_ROUTE, note)))
    }

    @Test fun tapOverANoteGoesBack() {
        assertTrue(tabTapGoesBack(feed, listOf(null, feed, note)))
        assertTrue(tabTapGoesBack(vault, listOf(null, feed, vault, note, note)))
    }

    @Test fun tapOnTheTabItselfScrollsInstead() {
        assertFalse(tabTapGoesBack(feed, listOf(null, feed)))
        assertFalse(tabTapGoesBack(vault, listOf(null, feed, vault)))
    }

    @Test fun tapOnAnotherTabsNoteDoesNotGoBack() {
        // The Feed under the Vault is not the lit tab.
        assertFalse(tabTapGoesBack(feed, listOf(null, feed, vault, note)))
        assertFalse(tabTapGoesBack(Screen.Search.route, listOf(null, feed, Screen.Search.route, note)))
    }
}
