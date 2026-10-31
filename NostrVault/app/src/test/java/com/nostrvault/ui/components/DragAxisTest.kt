package com.nostrvault.ui.components

import androidx.compose.ui.geometry.Offset
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Test

class DragAxisTest {

    private val slop = 18f

    @Test
    fun `undecided while travel is inside touch slop`() {
        // A first-frame wobble that is all vertical must not start a close.
        assertNull(decideDragAxis(Offset(1f, 6f), slop))
        assertNull(decideDragAxis(Offset(-12f, 12f), slop))
    }

    @Test
    fun `a sideways swipe with vertical wobble is horizontal`() {
        assertEquals(DragAxis.Horizontal, decideDragAxis(Offset(20f, 8f), slop))
        assertEquals(DragAxis.Horizontal, decideDragAxis(Offset(-15f, 15f), slop))
    }

    @Test
    fun `a clear pull down or up is vertical`() {
        assertEquals(DragAxis.Vertical, decideDragAxis(Offset(3f, 25f), slop))
        assertEquals(DragAxis.Vertical, decideDragAxis(Offset(-5f, -30f), slop))
    }
}
