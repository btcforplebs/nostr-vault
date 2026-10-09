package com.nostrvault.ui.components

import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

class MediaZoomGeometryTest {

    private val eps = 1e-3f

    /** Where [r] lands after [t] (scale about the origin, then translate). */
    private fun apply(t: ZoomTransform, r: ZoomRect) = ZoomRect(
        r.left * t.scale + t.translationX,
        r.top * t.scale + t.translationY,
        r.width * t.scale,
        r.height * t.scale,
    )

    private fun assertRect(expected: ZoomRect, actual: ZoomRect) {
        assertEquals(expected.left, actual.left, eps)
        assertEquals(expected.top, actual.top, eps)
        assertEquals(expected.width, actual.width, eps)
        assertEquals(expected.height, actual.height, eps)
    }

    @Test
    fun `landscape image fits to the container width, centred vertically`() {
        assertRect(ZoomRect(0f, 750f, 1000f, 500f), MediaZoomGeometry.fit(2f, 1000f, 2000f))
    }

    @Test
    fun `portrait image taller than the container fits to its height, centred horizontally`() {
        assertRect(ZoomRect(250f, 0f, 500f, 1000f), MediaZoomGeometry.fit(0.5f, 1000f, 1000f))
    }

    @Test
    fun `an unknown ratio fills the container`() {
        assertRect(ZoomRect(0f, 0f, 1000f, 2000f), MediaZoomGeometry.fit(0f, 1000f, 2000f))
    }

    @Test
    fun `fit transform lands the full-screen image exactly on a same-shaped feed card`() {
        val fitted = MediaZoomGeometry.fit(2f, 1000f, 2000f)
        val card = ZoomRect(40f, 300f, 400f, 200f)
        val t = MediaZoomGeometry.transform(fitted, card, crop = false)
        assertRect(card, apply(t, fitted))
    }

    @Test
    fun `fit transform keeps a letterboxed image inside its box`() {
        // A portrait photo in a capped-height card: it fits within the box.
        val fitted = MediaZoomGeometry.fit(0.5f, 1000f, 2000f)
        val card = ZoomRect(0f, 100f, 1000f, 600f)
        val landed = apply(MediaZoomGeometry.transform(fitted, card, crop = false), fitted)
        assertEquals(600f, landed.height, eps)
        assertEquals(300f, landed.width, eps)
        assertEquals(card.centerX, landed.centerX, eps)
        assertEquals(card.centerY, landed.centerY, eps)
    }

    @Test
    fun `crop transform covers a square grid cell`() {
        val fitted = MediaZoomGeometry.fit(2f, 1000f, 2000f) // 1000 x 500
        val cell = ZoomRect(300f, 900f, 330f, 330f)
        val landed = apply(MediaZoomGeometry.transform(fitted, cell, crop = true), fitted)
        assertEquals(330f, landed.height, eps)
        assertEquals(660f, landed.width, eps)
        assertEquals(cell.centerX, landed.centerX, eps)
        assertEquals(cell.centerY, landed.centerY, eps)
    }

    @Test
    fun `the source mapped into local coordinates comes back out on the source`() {
        val fitted = MediaZoomGeometry.fit(1.5f, 1080f, 2400f)
        val cell = ZoomRect(10f, 700f, 350f, 350f)
        val t = MediaZoomGeometry.transform(fitted, cell, crop = true)
        assertRect(cell, apply(t, MediaZoomGeometry.toLocal(cell, t)))
    }

    @Test
    fun `interpolation runs from the source transform to identity`() {
        val from = ZoomTransform(0.25f, 100f, -40f)
        assertEquals(from, MediaZoomGeometry.interpolate(from, 0f))
        assertEquals(ZoomTransform.Identity, MediaZoomGeometry.interpolate(from, 1f))
        val mid = MediaZoomGeometry.interpolate(from, 0.5f)
        assertEquals(0.625f, mid.scale, eps)
        assertEquals(50f, mid.translationX, eps)
        assertEquals(-20f, mid.translationY, eps)
    }

    @Test
    fun `clip interpolation clamps a spring's overshoot`() {
        val a = ZoomRect(0f, 0f, 10f, 10f)
        val b = ZoomRect(0f, 0f, 100f, 100f)
        assertRect(b, MediaZoomGeometry.lerpRect(a, b, 1.08f))
        assertRect(a, MediaZoomGeometry.lerpRect(a, b, -0.1f))
    }

    @Test
    fun `a source mostly on screen is a zoom target`() {
        val full = ZoomRect(0f, -100f, 1000f, 400f)
        val visible = ZoomRect(0f, 0f, 1000f, 300f)
        assertTrue(MediaZoomGeometry.isOnScreen(full, visible))
    }

    @Test
    fun `a source scrolled almost out of view falls back to a fade`() {
        val full = ZoomRect(0f, -380f, 1000f, 400f)
        val visible = ZoomRect(0f, 0f, 1000f, 20f)
        assertFalse(MediaZoomGeometry.isOnScreen(full, visible))
    }

    @Test
    fun `a source clipped to nothing is not a zoom target`() {
        assertFalse(MediaZoomGeometry.isOnScreen(ZoomRect(0f, 0f, 100f, 100f), ZoomRect(0f, 0f, 0f, 0f)))
        assertFalse(MediaZoomGeometry.isOnScreen(ZoomRect(0f, 0f, 0f, 0f), ZoomRect(0f, 0f, 0f, 0f)))
    }
}
