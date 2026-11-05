package com.nostrvault.ui.screens.pairing

import com.nostrvault.fips.MeshPairing
import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Test

/** The device name in the pairing code: the model for now (Logen still picks the defaults). */
class PairDeviceNameTest {
    @Test
    fun makerIsAddedOnce() {
        assertEquals("Motorola moto g play - 2026", PairDeviceViewModel.deviceName("motorola", "moto g play - 2026"))
        assertEquals("Google Pixel 9", PairDeviceViewModel.deviceName("Google", "Pixel 9"))
        assertEquals("Samsung SM-S921B", PairDeviceViewModel.deviceName("samsung", "SM-S921B"))
        assertEquals("OnePlus 12", PairDeviceViewModel.deviceName("OnePlus", "OnePlus 12"))
    }

    @Test
    fun emptyAndLongNames() {
        assertEquals("Android phone", PairDeviceViewModel.deviceName("", ""))
        assertTrue(PairDeviceViewModel.deviceName("x", "y".repeat(80)).length <= MeshPairing.NAME_MAX)
    }
}
