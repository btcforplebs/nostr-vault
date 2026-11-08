package com.nostrvault.ui.screens.pairing

import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test
import java.io.File

/**
 * Logen 2026-11-08 (main NV 1aab50b6), Android as iPhone 11-05: My Devices › Add a device opens the two scans; each
 * code shows as text with Copy code; every code or scan step has Paste instead (a code, or a bare mesh address for the
 * one-way add). The old "Add a device by address" sheet is gone, and the mesh is not called a VPN.
 */
class AddADeviceScreenTest {
    private fun main(rel: String): File =
        listOf("src/main/java/com/nostrvault/$rel", "app/src/main/java/com/nostrvault/$rel").map(::File).first { it.parentFile.exists() }

    private fun source(rel: String) = main(rel).readText()

    /** One `is PairDeviceViewModel.Ui.<step> ->` branch of the screen. */
    private fun step(screen: String, name: String) =
        screen.substringAfter("is PairDeviceViewModel.Ui.$name ->").substringBefore("is PairDeviceViewModel.Ui.")

    @Test
    fun `my devices add opens the two scans, not the by-address sheet`() {
        val screen = source("ui/screens/settings/fipsmesh/FipsMeshScreen.kt")
        assertTrue(screen.contains("MyDevicesSection(devices, status.running, onOpenDevice, onLinkDevice)"))
        assertTrue(screen.substringAfter("private fun MyDevicesSection").contains("Text(ADD_A_DEVICE"))
        assertEquals("Add a device", com.nostrvault.ui.screens.settings.fipsmesh.ADD_A_DEVICE)
        assertFalse(screen.contains("AddDeviceSheet"))
        assertFalse("the by-address sheet is back", main("ui/screens/settings/fipsmesh/FipsMeshAddSheet.kt").exists())
        val all = main("ui/screens/settings/fipsmesh/FipsMeshScreen.kt").parentFile.listFiles()!!.joinToString("\n") { it.readText() }
        assertFalse(all.contains("\"Add a device by address\""))
        val vm = source("ui/screens/settings/fipsmesh/FipsMeshViewModel.kt")
        assertFalse(vm.contains("val suggestions") || vm.contains("fun addDevice("))
    }

    @Test
    fun `every code has Copy code and every scan step has Paste instead`() {
        val screen = source("ui/screens/pairing/PairDeviceScreen.kt")
        assertEquals("Copy code", COPY_CODE)
        assertEquals("Paste instead", PASTE_INSTEAD)
        for (s in listOf("ShowCode", "ShowMyCode")) assertTrue("$s has no Copy code", step(screen, s).contains("CodeText(s.uri)"))
        for (s in listOf("ShowCode", "ScanFirst", "ScanTheirs")) assertTrue("$s has no Paste instead", step(screen, s).contains("PasteField(viewModel::pasted)"))
        assertTrue(step(screen, "ByAddress").contains("ByAddressStep(s.npub, viewModel::addByAddress"))
    }

    @Test
    fun `the mesh is not a VPN`() {
        val media = source("ui/screens/settings/BlossomSettingsScreen.kt")
        assertFalse(media.contains("\"VPN active\"") || media.contains("No VPN detected") || media.contains("FIPS VPN"))
        assertFalse(media.contains("TRANSPORT_VPN"))
    }
}
