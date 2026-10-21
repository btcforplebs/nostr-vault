package com.nostrvault.ui.components

import androidx.compose.ui.unit.dp
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

class WotSidePanelTest {
    @Test fun phoneAndNarrowTabletKeepTheBottomCard() {
        assertFalse(wotCardIsSidePanel(411.dp))
        assertFalse(wotCardIsSidePanel(899.dp))
    }

    @Test fun wideWindowDocksTheCard() {
        assertTrue(wotCardIsSidePanel(900.dp))
        assertTrue(wotCardIsSidePanel(1280.dp))
    }
}
