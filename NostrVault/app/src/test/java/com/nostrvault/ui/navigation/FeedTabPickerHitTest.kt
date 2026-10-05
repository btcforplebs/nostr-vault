package com.nostrvault.ui.navigation

import androidx.compose.ui.geometry.Offset
import androidx.compose.ui.geometry.Rect
import com.nostrvault.data.model.FeedMode
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Test

/** Hold-the-Feed-tab: the finger picks the row it is over (iOS #239). */
class FeedTabPickerHitTest {

    private val rows = mapOf(
        FeedMode.FOLLOWING to Rect(100f, 900f, 520f, 984f),
        FeedMode.DISCOVERY to Rect(100f, 812f, 520f, 896f),
    )

    @Test fun `finger over a row picks it`() {
        assertEquals(FeedMode.FOLLOWING, feedModeAt(rows, Offset(300f, 950f)))
        assertEquals(FeedMode.DISCOVERY, feedModeAt(rows, Offset(300f, 850f)))
    }

    @Test fun `a little to the side still counts`() {
        assertEquals(FeedMode.FOLLOWING, feedModeAt(rows, Offset(80f, 950f)))
    }

    @Test fun `the gap between rows and far away pick nothing`() {
        assertNull(feedModeAt(rows, Offset(300f, 898f)))
        assertNull(feedModeAt(rows, Offset(300f, 1200f)))
        assertNull(feedModeAt(rows, Offset(10f, 950f)))
    }
}
