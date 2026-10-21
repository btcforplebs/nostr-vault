package com.nostrvault.ui.navigation

import com.nostrvault.tutorials.TutorialID
import org.junit.Assert.assertEquals
import org.junit.Test

/** Replay and "Next" open the tab a tutorial's cards point at. WoT once
 *  fell through to Feed and drew its three cards with no arrows. */
class TutorialRouteTest {
    private val expected = mapOf(
        TutorialID.FILL_YOUR_VAULT to Screen.Feed.route,
        TutorialID.FEEDS to Screen.Feed.route,
        TutorialID.IMPORT_TOUR to Screen.Feed.route,
        TutorialID.WOT to Screen.WOT.route,
        TutorialID.VAULT to Screen.Dashboard.route,
        TutorialID.POCKET_RELAY to Screen.Dashboard.route,
        TutorialID.WALLET_CONNECT to Screen.Wallet.route,
    )

    @Test
    fun everyTutorialOpensItsOwnTab() {
        assertEquals(TutorialID.entries.toSet(), expected.keys)
        for (id in TutorialID.entries) assertEquals(id.name, expected[id], tutorialRoute(id))
    }
}
