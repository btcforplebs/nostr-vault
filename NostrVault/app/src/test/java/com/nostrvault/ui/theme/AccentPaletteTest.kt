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

    @Test fun orangeDefaultMatchesItsComputedRamp() {
        assertEquals(AppTheme.DEFAULT.colors, AccentPalette.ramp("orange", light = false).scheme)
        assertEquals(AppTheme.DEFAULT.lightColors, AccentPalette.ramp("#E67326", light = true).scheme)
        assertEquals(Color.White, AccentPalette.ramp("orange", light = true).onAccent)
    }

    @Test fun everyPresetReadsAsTextInBothModes() {
        for (p in AccentPalette.presets) {
            val light = AccentPalette.ramp(p.hex, light = true)
            val dark = AccentPalette.ramp(p.hex, light = false)
            assertTrue("${p.name} light text", contrast(light.scheme.primaryText, Color.White) >= 3.45f)
            assertTrue("${p.name} dark text", contrast(dark.scheme.primaryText, Color(0xFF1C1C1E)) >= 4.4f)
            assertTrue("${p.name} label", contrast(light.onAccent, light.scheme.primary) >= 2.9f)
        }
    }

    private fun hex(c: Color): String {
        val v = (c.value shr 32).toLong() and 0xFFFFFF
        return "#%06x".format(v)
    }

    /** The row Logen picked (nv-ui c5abde71), same numbers as test/accent.test.mjs. */
    @Test fun neonInDarkExactFillsInLightOnlyPaleTextDarkened() {
        val neon = linkedMapOf(
            "#e67326" to "#ea7013", "#ffb800" to "#ffb800", "#3ddc84" to "#1fde7f", "#00c2b8" to "#00c2b8",
            "#2e7dff" to "#327fff", "#662482" to "#c641fc", "#ff2d87" to "#ff2d87", "#a8071a" to "#fc2c37",
        )
        val darkened = setOf("#e67326", "#ffb800", "#3ddc84", "#00c2b8")
        assertEquals(neon.keys.toList(), AccentPalette.presets.map { it.hex })
        for (p in AccentPalette.presets) {
            val dark = AccentPalette.ramp(p.hex, light = false).scheme
            val light = AccentPalette.ramp(p.hex, light = true).scheme
            assertEquals("${p.name} dark", neon[p.hex], hex(dark.primary))
            assertEquals("${p.name} dark text", neon[p.hex], hex(dark.primaryText))
            assertEquals("${p.name} neonHex", neon[p.hex], AccentPalette.neonHex(p.hex))
            assertEquals("${p.name} light fill exact", p.hex, hex(light.primary))
            if (p.hex in darkened) {
                assertTrue("${p.name} light text darkened", hex(light.primaryText) != p.hex && contrast(light.primaryText, Color.White) >= 4.4f)
            } else {
                assertEquals("${p.name} light text exact", p.hex, hex(light.primaryText))
            }
        }
        assertEquals("#c35400", hex(AccentPalette.ramp("orange", light = true).scheme.primaryText))
    }

    @Test fun greysStayGreyInDark() {
        assertEquals("#868686", AccentPalette.neonHex("#000000"))
        assertEquals("#ffffff", AccentPalette.neonHex("#ffffff"))
    }

    @Test fun paleColoursGetABlackLabelInDark() {
        assertEquals(Color.Black, AccentPalette.ramp("#ffd60a", light = false).onAccent)
        assertEquals(Color.White, AccentPalette.ramp("#0a84ff", light = false).onAccent)
    }

    @Test fun settingRoundTrips() {
        assertEquals("orange", AccentPalette.setting("#E67326"))
        assertEquals("#00c2b8", AccentPalette.setting("#00C2B8"))
        assertEquals(AccentPalette.DEFAULT_HEX, AccentPalette.hex("purple"))
    }

    /** Wheel picks can be anything, white and black included; every one must still read. */
    @Test fun wheelPicksStayReadableInBothModes() {
        for (hex in listOf("#ffffff", "#000000", "#f0f0a0", "#80ffff", "#ff8080", "#3c1e5a", "#7f7f7f")) {
            val light = AccentPalette.ramp(hex, light = true)
            val dark = AccentPalette.ramp(hex, light = false)
            assertTrue("$hex light text", contrast(light.scheme.primaryText, Color.White) >= 3.45f)
            assertTrue("$hex dark text", contrast(dark.scheme.primaryText, Color(0xFF1C1C1E)) >= 4.4f)
            assertTrue("$hex light label", contrast(light.onAccent, light.scheme.primary) >= 2.9f)
            assertTrue("$hex dark label", contrast(dark.onAccent, dark.scheme.primary) >= 2.9f)
        }
        assertTrue(AccentPalette.shiftsInLight("#f0f0a0"))
        assertEquals(Color.Black, AccentPalette.ramp("#f0f0a0", light = false).onAccent)
    }

    @Test fun onlyTheReadyMadeRowCountsAsPreset() {
        assertTrue(AccentPalette.isPreset("#FFB800"))
        assertTrue(!AccentPalette.isPreset("#123456"))
    }

    /** Same numbers as web paper() (test/accent.test.mjs): warm paper + 5% of the accent. */
    @Test fun lightPaperMixesFivePercentOfTheAccent() {
        assertEquals(Color(0xFFF5EBE1), AccentPalette.paper("orange"))
        assertEquals(Color(0xFFEAECEC), AccentPalette.paper("#0a84ff"))
    }
}
