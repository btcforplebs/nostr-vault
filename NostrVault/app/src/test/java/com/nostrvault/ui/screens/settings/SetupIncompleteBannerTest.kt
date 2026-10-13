package com.nostrvault.ui.screens.settings

import com.nostrvault.relay.HavenConfig
import com.nostrvault.ui.navigation.Screen
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

/**
 * The "Setup Incomplete" banner at the top of Settings (iOS SettingsView):
 * there while setup isn't finished, above the relay card, opening the wizard;
 * gone once setup is done.
 */
class SetupIncompleteBannerTest {

    @Test fun shownFirstWhileSetupIsUnfinished() {
        assertEquals(
            listOf(SettingsTopItem.SETUP_INCOMPLETE, SettingsTopItem.RELAY_STATUS),
            settingsTopItems(HavenConfig(hasCompletedSetup = false)),
        )
    }

    @Test fun goneOnceSetupIsDone() {
        assertEquals(listOf(SettingsTopItem.RELAY_STATUS), settingsTopItems(HavenConfig(hasCompletedSetup = true)))
    }

    @Test fun aNewInstallHasNotFinishedSetup() {
        assertTrue(SettingsTopItem.SETUP_INCOMPLETE in settingsTopItems(HavenConfig.newInstall()))
    }

    @Test fun opensTheSetupWizard() {
        assertEquals(Screen.SetupWizard, SETUP_INCOMPLETE_DESTINATION)
    }

    @Test fun aWizardOpenedFromSettingsGoesBackThere() {
        assertTrue(setupWizardReturnsToSettings(Screen.Settings.route))
        // First run: the wizard is where the app starts.
        assertFalse(setupWizardReturnsToSettings(null))
        assertFalse(setupWizardReturnsToSettings(Screen.Feed.route))
    }
}
