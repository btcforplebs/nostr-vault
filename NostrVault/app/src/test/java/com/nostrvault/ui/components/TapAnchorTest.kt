package com.nostrvault.ui.components

import androidx.compose.ui.unit.dp
import org.junit.Assert.assertEquals
import org.junit.Test

/** The tap line: 20 dp under the top buttons, in detail and the feed (Logen 10-28). */
class TapAnchorTest {
    @Test fun theLineIsTwentyUnderTheButtonsAndTwelveUnderTheBar() {
        assertEquals(20.dp, TapAnchor.UNDER_BUTTONS)
        assertEquals(12.dp, TapAnchor.BELOW_TOOLBAR)
    }

    @Test fun roomBelowLetsTheLastRowReachTheLine() {
        // 800 tall, 112 above the line, 150 of bottom bar: 538 below a row's top.
        assertEquals(538.dp, TapAnchor.roomBelow(800.dp, 112.dp, 150.dp))
    }

    @Test fun roomBelowNeverGoesUnderItsFloor() {
        assertEquals(32.dp, TapAnchor.roomBelow(0.dp, 112.dp, 150.dp, min = 32.dp))
        assertEquals(0.dp, TapAnchor.roomBelow(100.dp, 112.dp, 150.dp))
    }
}
