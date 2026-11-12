package com.nostrvault.ui.screens.settings

import com.nostrvault.relay.HavenConfig
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

/** Multi-Mac rules §3: the full-copy switch and the one web device. Twin of iOS MultiMacLogicTests. */
class YourDevicesFullCopyRulesTest {
    @Test
    fun `mobile vault mode keeps a full copy and locks the switch`() {
        assertTrue(YourDevicesRules.keepsFullCopy(mobileVault = true, stored = false))
        assertTrue(YourDevicesRules.keepsFullCopy(mobileVault = false, stored = true))
        assertFalse(YourDevicesRules.keepsFullCopy(mobileVault = false, stored = false))
        assertTrue("every phone, new or existing, starts on", YourDevicesRules.keepsFullCopy(mobileVault = false, stored = null))
        assertTrue(YourDevicesRules.fullCopyLocked(mobileVault = true))
        assertFalse(YourDevicesRules.fullCopyLocked(mobileVault = false))
    }

    @Test
    fun `catch-up moves files only for a full copy, and wifi only defaults on`() {
        assertFalse(YourDevicesRules.catchUpMovesFiles(fullCopy = false, wifiOnly = null, onWiFi = true))
        assertTrue(YourDevicesRules.catchUpMovesFiles(fullCopy = true, wifiOnly = null, onWiFi = true))
        assertFalse(YourDevicesRules.catchUpMovesFiles(fullCopy = true, wifiOnly = null, onWiFi = false))
        assertTrue(YourDevicesRules.catchUpMovesFiles(fullCopy = true, wifiOnly = false, onWiFi = false))
    }

    @Test
    fun `the switches default unset`() {
        assertNull(HavenConfig().keepFullCopy)
        assertNull(HavenConfig().fullCopyWifiOnly)
    }

    private val domains = mapOf("npub1maca" to "a.example.com", "npub1macb" to "b.example.com")

    @Test
    fun `the web device is the own domain the newest list names first`() {
        assertEquals("npub1maca", YourDevicesRules.webDevice(listOf("https://blossom.primal.net", "https://A.example.com/", "https://b.example.com"), domains))
        assertEquals("npub1macb", YourDevicesRules.webDevice(listOf("https://b.example.com", "fipsmesh://npub1maca/"), domains))
        assertNull("outside servers aren't devices", YourDevicesRules.webDevice(listOf("https://blossom.primal.net"), domains))
        assertNull("https only", YourDevicesRules.webDevice(listOf("http://a.example.com"), domains))
        assertNull(YourDevicesRules.webDevice(emptyList(), domains))
    }

    @Test
    fun `host drops scheme, port, path and case`() {
        assertEquals("a.example.com", YourDevicesRules.host("https://A.Example.com:8443/x"))
        assertEquals("a.example.com", YourDevicesRules.host("a.example.com"))
        assertNull(YourDevicesRules.host("  "))
    }
}
