package com.nostrvault.ui.screens.dm

import androidx.compose.ui.unit.dp
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

/** Side by side only where the conversation column stays wider than a phone (iOS DMInboxMetrics). */
class DMTwoPaneTest {

    @Test
    fun phonesPushTheThread() {
        assertFalse(dmUsesTwoPane(360.dp))
        assertFalse(dmUsesTwoPane(699.dp))
    }

    @Test
    fun tabletsAndUnfoldedPhonesShowBoth() {
        assertTrue(dmUsesTwoPane(700.dp))
        assertTrue(dmUsesTwoPane(1280.dp))
    }
}
