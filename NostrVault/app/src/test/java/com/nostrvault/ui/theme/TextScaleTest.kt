package com.nostrvault.ui.theme

import org.junit.Assert.assertEquals
import org.junit.Test

class TextScaleTest {

    @Test
    fun `the user preference multiplies the system font scale`() {
        // Not replaces. The OS accessibility font size is a setting the user also
        // chose; overriding it would make this control silently undo that one.
        assertEquals(1.6f, scaledFontScale(systemFontScale = 1.0f, userScale = 1.6f), 1e-6f)
        assertEquals(1.8f, scaledFontScale(systemFontScale = 1.5f, userScale = 1.2f), 1e-6f)
    }

    @Test
    fun `the default preference changes nothing`() {
        assertEquals(1.3f, scaledFontScale(systemFontScale = 1.3f, userScale = 1.0f), 1e-6f)
    }

    @Test
    fun `the whole slider range passes through untouched`() {
        // The control is 0.8-1.6, so the clamp must not be tighter than the UI.
        assertEquals(0.8f, scaledFontScale(1f, 0.8f), 1e-6f)
        assertEquals(1.6f, scaledFontScale(1f, 1.6f), 1e-6f)
    }

    @Test
    fun `a corrupt preference cannot render the app at zero height`() {
        // This value comes from persisted config, not from the slider that made
        // it. Zero or negative would draw every string in the app at no height,
        // which is indistinguishable from a blank screen.
        assertEquals(MIN_TEXT_SCALE, scaledFontScale(1f, 0f), 1e-6f)
        assertEquals(MIN_TEXT_SCALE, scaledFontScale(1f, -3f), 1e-6f)
        assertEquals(MAX_TEXT_SCALE, scaledFontScale(1f, 99f), 1e-6f)
    }

    @Test
    fun `a non-finite preference falls back rather than propagating NaN`() {
        assertEquals(1f, scaledFontScale(1f, Float.NaN), 1e-6f)
        assertEquals(1f, scaledFontScale(1f, Float.POSITIVE_INFINITY), 1e-6f)
    }

    @Test
    fun `a broken system font scale does not take the preference down with it`() {
        assertEquals(1.6f, scaledFontScale(systemFontScale = 0f, userScale = 1.6f), 1e-6f)
        assertEquals(1.6f, scaledFontScale(systemFontScale = Float.NaN, userScale = 1.6f), 1e-6f)
    }

    @Test
    fun `the ramp itself carries no scaling`() {
        // Two mechanisms would multiply. The density override owns scaling, so
        // these slots must stay at their design sizes.
        val t = nostrVaultTypography()
        assertEquals(34f, t.displayLarge.fontSize.value, 1e-6f)
        assertEquals(17f, t.titleMedium.fontSize.value, 1e-6f)
        assertEquals(11f, t.labelSmall.fontSize.value, 1e-6f)
    }
}
