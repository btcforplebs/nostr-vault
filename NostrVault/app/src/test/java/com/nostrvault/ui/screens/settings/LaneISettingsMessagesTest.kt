package com.nostrvault.ui.screens.settings

import org.junit.Assert.assertEquals
import org.junit.Test

/** The confirm texts in Settings, word for word as iOS. */
class LaneISettingsMessagesTest {

    @Test
    fun `clear cache message names the size once it is known`() {
        assertEquals(
            "Removes temporary copies of images and videos. They download again when you view them. Your vault and your Blossom servers are not touched.",
            AdvancedSettingsViewModel.clearMessage(null),
        )
        assertEquals(
            "Removes 2.0 MB of temporary copies of images and videos. They download again when you view them. Your vault and your Blossom servers are not touched.",
            AdvancedSettingsViewModel.clearMessage(2L * 1024 * 1024),
        )
    }

    @Test
    fun `factory reset says the app restarts, not quits`() {
        assertEquals(
            "This action cannot be undone. All your relay data will be lost and the app will restart.",
            FACTORY_RESET_MESSAGE,
        )
    }

    @Test
    fun `restore message gives both counts and the source`() {
        assertEquals(
            "This will replace your current 1018 follows with 990 follows from this snapshot and publish the updated list to your relays.",
            restoreMessage(1018, 990, "snapshot"),
        )
    }
}
