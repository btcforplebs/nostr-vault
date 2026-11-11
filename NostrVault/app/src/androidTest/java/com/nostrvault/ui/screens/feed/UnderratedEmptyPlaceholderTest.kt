package com.nostrvault.ui.screens.feed

import androidx.compose.ui.test.assertHasClickAction
import androidx.compose.ui.test.assertIsNotEnabled
import androidx.compose.ui.test.junit4.createComposeRule
import androidx.compose.ui.test.onNodeWithText
import androidx.compose.ui.test.performClick
import androidx.test.ext.junit.runners.AndroidJUnit4
import com.nostrvault.service.UnderratedEmptyReason
import com.nostrvault.ui.theme.NostrVaultTheme
import org.junit.Assert.assertEquals
import org.junit.Rule
import org.junit.Test
import org.junit.runner.RunWith

/**
 * Underrated's empty screen draws the button the relay's reason calls for (Logen 2026-11-11: a follows-only web
 * offered Refresh, which cannot help). Renders the real composable and taps it.
 */
@RunWith(AndroidJUnit4::class)
class UnderratedEmptyPlaceholderTest {
    @get:Rule val rule = createComposeRule()

    private var refreshes = 0
    private var builds = 0

    private fun show(reason: UnderratedEmptyReason?, building: Boolean = false) {
        rule.setContent {
            NostrVaultTheme {
                UnderratedEmptyPlaceholder(reason, building, onRefresh = { refreshes++ }, onBuildWiderNetwork = { builds++ })
            }
        }
    }

    @Test
    fun webIncompleteOffersBuildYourWiderNetwork() {
        show(UnderratedEmptyReason.WEB_INCOMPLETE)
        rule.onNodeWithText("Underrated needs your wider web").assertExists()
        rule.onNodeWithText("Refresh Feed").assertDoesNotExist()
        rule.onNodeWithText("Build your wider network").assertHasClickAction().performClick()
        assertEquals(1, builds)
        assertEquals(0, refreshes)
    }

    @Test
    fun nothingQualifiedKeepsRefreshFeed() {
        show(UnderratedEmptyReason.NOTHING_QUALIFIED)
        rule.onNodeWithText("No Underrated Notes Found").assertExists()
        rule.onNodeWithText("Build your wider network").assertDoesNotExist()
        rule.onNodeWithText("Refresh Feed").performClick()
        assertEquals(1, refreshes)
        assertEquals(0, builds)
    }

    @Test
    fun noReasonKeepsRefreshFeed() {
        show(null)
        rule.onNodeWithText("Refresh Feed").assertExists()
        rule.onNodeWithText("Build your wider network").assertDoesNotExist()
    }

    @Test
    fun buildingShowsItIsRunningAndCannotBeTappedAgain() {
        show(UnderratedEmptyReason.WEB_INCOMPLETE, building = true)
        rule.onNodeWithText("Underrated needs your wider web").assertExists()
        rule.onNodeWithText("Build your wider network").assertDoesNotExist()
        rule.onNodeWithText("Refresh Feed").assertDoesNotExist()
        rule.onNodeWithText("Building your wider network…").assertIsNotEnabled()
        assertEquals(0, builds)
    }
}
