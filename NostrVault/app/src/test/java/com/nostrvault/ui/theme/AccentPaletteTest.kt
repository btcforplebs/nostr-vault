package com.nostrvault.ui.theme

import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.luminance
import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Test

class AccentPaletteTest {
    private fun contrast(a: Color, b: Color): Float {
        val x = a.luminance(); val y = b.luminance()
        return (maxOf(x, y) + 0.05f) / (minOf(x, y) + 0.05f)
    }

    @Test fun orangeKeepsItsHandTunedRamp() {
        assertEquals(AppTheme.DEFAULT.colors, AccentPalette.ramp("orange", light = false).scheme)
        assertEquals(AppTheme.DEFAULT.lightColors, AccentPalette.ramp("#E67326", light = true).scheme)
        assertEquals(Color.White, AccentPalette.ramp("orange", light = true).onAccent)
    }

    @Test fun everyPresetReadsAsTextInBothModes() {
        for (p in AccentPalette.presets) {
            val light = AccentPalette.ramp(p.hex, light = true)
            val dark = AccentPalette.ramp(p.hex, light = false)
            assertTrue("${p.name} light text", contrast(light.scheme.primary, Color.White) >= 4.4f)
            assertTrue("${p.name} dark text", contrast(dark.scheme.primary, Color(0xFF1C1C1E)) >= 4.4f)
            assertTrue("${p.name} label", contrast(light.onAccent, light.scheme.primary) >= 2.9f)
        }
    }

    @Test fun paleColoursGetABlackLabelInDark() {
        assertEquals(Color.Black, AccentPalette.ramp("#ffd60a", light = false).onAccent)
        assertEquals(Color.White, AccentPalette.ramp("#0a84ff", light = false).onAccent)
    }

    @Test fun settingRoundTrips() {
        assertEquals("orange", AccentPalette.setting("#E67326"))
        assertEquals("#40c8e0", AccentPalette.setting("#40C8E0"))
        assertEquals(AccentPalette.DEFAULT_HEX, AccentPalette.hex("purple"))
    }
}
