package com.nostrvault.ui.screens.settings.fipsmesh

import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test
import java.io.File

/**
 * Mesh settings › This Device (Logen 2026-11-05): the old Copy and bare-address QR (fipsmesh://<npub>/), which the
 * two-scan flow refuses, are gone; Link a device opens the pairing screen; Copy lives under Advanced.
 */
class ThisDeviceLinkTest {
    private fun source(name: String): String {
        val candidates = listOf(
            "src/main/java/com/nostrvault/ui/screens/settings/fipsmesh/$name",
            "app/src/main/java/com/nostrvault/ui/screens/settings/fipsmesh/$name",
        )
        return candidates.map(::File).first { it.exists() }.readText()
    }

    @Test
    fun `this device offers Link a device, not a bare-address QR or Copy`() {
        val screen = source("FipsMeshScreen.kt")
        val section = screen.substringAfter("private fun ThisDeviceSection").substringBefore("private fun MyDevicesSection")
        assertFalse("bare-address QR still on This Device", section.contains("fipsmesh://"))
        assertFalse("Show QR still on This Device", section.contains("Show QR"))
        assertFalse("Copy still on This Device", section.contains("Text(\"Copy\")"))
        assertTrue(section.contains("LINK_A_DEVICE") && section.contains("onLinkDevice"))
        assertEquals("Link a device", LINK_A_DEVICE)
    }

    @Test
    fun `copy moved to Advanced`() {
        assertTrue(source("FipsMeshAdvancedScreen.kt").contains("Text(\"Copy\")"))
    }

    @Test
    fun `link a device opens the pairing screen`() {
        val routes = listOf("src/main/java/com/nostrvault/ui/navigation/SettingsRoutes.kt", "app/src/main/java/com/nostrvault/ui/navigation/SettingsRoutes.kt")
            .map(::File).first { it.exists() }.readText()
        assertTrue(routes.contains("onLinkDevice = { navController.navigate(Screen.PairDevice.route) }"))
    }
}
