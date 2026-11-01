package com.nostrvault.ui.navigation

import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

/** The bottom bar stays on the screens iOS pushes inside a tab, and only those. */
class BottomBarRoutesTest {
    @Test fun tabsKeepTheBar() {
        listOf(Screen.Feed, Screen.Search, Screen.Dashboard, Screen.WOT).forEach {
            assertTrue(it.route, showsBottomBar(it.route))
        }
    }

    @Test fun pushedScreensKeepTheBar() {
        listOf(Screen.NoteDetail, Screen.Profile, Screen.ArticleReader, Screen.AddressLink, Screen.FollowList).forEach {
            assertTrue(it.route, showsBottomBar(it.route))
        }
    }

    @Test fun sheetsOnIosCoverTheBar() {
        listOf(Screen.ComposeNote, Screen.Settings, Screen.DMThread, Screen.HashtagFeed, Screen.SetupWizard, Screen.MediaViewer).forEach {
            assertFalse(it.route, showsBottomBar(it.route))
        }
        assertFalse(showsBottomBar(null))
    }

    @Test fun miniPlayerShowsWhereTheBarShows() {
        listOf(Screen.Feed, Screen.Search, Screen.Dashboard, Screen.WOT,
            Screen.NoteDetail, Screen.Profile, Screen.ArticleReader, Screen.AddressLink, Screen.FollowList).forEach {
            assertTrue(it.route, showsMiniPlayer(it.route))
        }
    }

    @Test fun miniPlayerStaysOffEveryOtherScreen() {
        listOf(Screen.ComposeNote, Screen.ModeCompose, Screen.Drafts, Screen.Settings, Screen.AppearanceSettings,
            Screen.DMInbox, Screen.DMThread, Screen.NewMessage, Screen.HashtagFeed, Screen.MediaViewer,
            Screen.Wallet, Screen.BitcoinWallet, Screen.SetupWizard, Screen.FeedDashboard,
            Screen.RelayActivity, Screen.LogViewer).forEach {
            assertFalse(it.route, showsMiniPlayer(it.route))
        }
        assertFalse(showsMiniPlayer(null))
    }
}
