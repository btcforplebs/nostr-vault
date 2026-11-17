package com.nostrvault.ui.theme

import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Test
import java.io.File

class IconAccentTest {
    @Test fun oneAliasPerPresetInOrder() {
        assertEquals(AccentPalette.presets.map { it.hex }, IconAccent.aliases.map { it.first })
        assertEquals(AccentPalette.presets.size, IconAccent.aliases.map { it.second }.toSet().size)
    }

    @Test fun presetIsItsOwnNearest() {
        for (p in AccentPalette.presets) assertEquals(p.name, p.hex, IconAccent.nearestPresetHex(p.hex))
    }

    /** Same cases as IconAccentTests.swift, so both apps pick the same icon. */
    @Test fun wheelColourTakesNearestPreset() {
        assertEquals("#a8071a", IconAccent.nearestPresetHex("#ff0000"))
        assertEquals("#2e7dff", IconAccent.nearestPresetHex("#0040ff"))
        assertEquals("#ffb800", IconAccent.nearestPresetHex("#ffd700"))
        assertEquals("#662482", IconAccent.nearestPresetHex("#7b2fa0"))
        assertEquals("#3ddc84", IconAccent.nearestPresetHex("#00FF7F"))
    }

    @Test fun offOrOrangeMeansTheAppsOwnIcon() {
        assertEquals("LauncherDefault", IconAccent.aliasFor("#2e7dff", follows = false))
        assertEquals("LauncherBlue", IconAccent.aliasFor("#2e7dff", follows = true))
        assertEquals("LauncherDefault", IconAccent.aliasFor("orange", follows = true))
        assertEquals("LauncherRed", IconAccent.aliasFor("#ff0000", follows = true))
    }

    /** Every alias is in the manifest with its own icon, only Default starts on, and the activity itself has no launcher entry. */
    @Test fun aliasesAreInTheManifest() {
        val manifest = File("src/main/AndroidManifest.xml").readText()
        for ((_, alias) in IconAccent.aliases) {
            val block = Regex("<activity-alias\\s+android:name=\"\\.$alias\"[\\s\\S]*?</activity-alias>").find(manifest)?.value
            assertTrue(alias, block != null)
            assertTrue(alias, block!!.contains("android.intent.category.LAUNCHER"))
            assertTrue(alias, block.contains("android:enabled=\"${alias == IconAccent.DEFAULT_ALIAS}\""))
            val icon = Regex("android:icon=\"@mipmap/(\\w+)\"").find(block)!!.groupValues[1]
            assertTrue(icon, File("src/main/res/mipmap-anydpi-v26/$icon.xml").exists())
        }
        val main = Regex("<activity\\s+android:name=\"\\.MainActivity\"[\\s\\S]*?</activity>").find(manifest)!!.value
        assertTrue(!main.contains("android.intent.category.LAUNCHER"))
    }
}
