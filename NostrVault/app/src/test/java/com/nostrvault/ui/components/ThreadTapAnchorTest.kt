package com.nostrvault.ui.components

import org.junit.Assert.assertEquals
import org.junit.Test

class ThreadTapAnchorTest {
    @Test fun `a visible line stays where it was tapped`() {
        assertEquals(640f, ThreadTapAnchor.target(lineTop = 640f, listTop = 120f))
    }

    @Test fun `a line whose top was above the list comes to the top edge`() {
        assertEquals(120f, ThreadTapAnchor.target(lineTop = -40f, listTop = 120f))
    }

    @Test fun `a line that moved up 150 px scrolls back down 150 px`() {
        // scrollBy(negative) moves content down.
        assertEquals(-150f, ThreadTapAnchor.correction(lineTop = 490f, target = 640f))
    }

    @Test fun `sub-pixel drift is left alone`() {
        assertEquals(0f, ThreadTapAnchor.correction(lineTop = 640.3f, target = 640f))
    }
}
