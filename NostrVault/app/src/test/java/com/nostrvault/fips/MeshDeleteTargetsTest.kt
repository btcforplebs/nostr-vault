package com.nostrvault.fips

import com.nostrvault.relay.HavenConfig
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

/** Delete everywhere reaches the owner's mesh devices; Delete from mirrors keeps their copies (Tod, 2026-10-31). */
class MeshDeleteTargetsTest {
    private val mac = "npub1qgpqyqszqgpqyqszqgpqyqszqgpqyqszqgpqyqszqgpqyqszqgpq2yz0cn"
    private val kiosk = "npub1qvpsxqcrqvpsxqcrqvpsxqcrqvpsxqcrqvpsxqcrqvpsxqcrqvps0km4w3"
    private val phone = "npub1qyqszqgpqyqszqgpqyqszqgpqyqszqgpqyqszqgpqyqszqgpqyqs8j9gdm"

    private fun config(devices: List<FipsDevice>, peers: List<String> = devices.map { it.npub }, home: String? = null) =
        HavenConfig(fipsPeers = peers, homeVaultNpub = home, fipsMesh = FipsMeshSettings(devices = devices))

    @Test
    fun `everywhere asks the home vault and every mac, media switch or not`() {
        val c = config(
            listOf(FipsDevice(mac, DeviceRole.MAC, name = "Studio Mac", sendMedia = false), FipsDevice(phone, DeviceRole.PHONE)),
            home = kiosk,
        )
        assertEquals(
            listOf(MeshDeleteTarget(kiosk, "the home vault"), MeshDeleteTarget(mac, "Studio Mac")),
            MeshDeleteTargets.of(c, includeHomeVault = true),
        )
    }

    @Test
    fun `an unnamed mac is your mac`() {
        assertEquals(
            listOf(MeshDeleteTarget(mac, "your home vault")),
            MeshDeleteTargets.of(config(listOf(FipsDevice(mac, DeviceRole.MAC, name = "  "))), includeHomeVault = true),
        )
    }

    @Test
    fun `mirrors only keeps the mesh copies`() {
        assertEquals(
            emptyList<MeshDeleteTarget>(),
            MeshDeleteTargets.of(config(listOf(FipsDevice(mac, DeviceRole.MAC)), home = kiosk), includeHomeVault = false),
        )
    }

    @Test
    fun `a mac no longer in my devices is not dialled`() {
        assertEquals(
            emptyList<MeshDeleteTarget>(),
            MeshDeleteTargets.of(config(listOf(FipsDevice(mac, DeviceRole.MAC)), peers = emptyList()), includeHomeVault = true),
        )
    }

    @Test
    fun `the report key never carries the ingress token`() {
        assertEquals("fipsmesh://$mac/", MeshDeleteTarget(mac, "your Mac").key)
    }

    @Test
    fun `gone needs the delete taken and a 404 after it`() {
        assertTrue(MeshDeleteTargets.gone(204, 404))
        assertTrue(MeshDeleteTargets.gone(200, 404))
        assertTrue(MeshDeleteTargets.gone(404, 404))
        // The mesh door has no DELETE and says 404, but still serves the file to the owner's "get".
        assertFalse(MeshDeleteTargets.gone(404, 200))
        // Another key also owns the blob: the entry went, the file stayed.
        assertFalse(MeshDeleteTargets.gone(204, 200))
        assertFalse(MeshDeleteTargets.gone(401, 404))
        assertFalse(MeshDeleteTargets.gone(204, null))
        assertFalse(MeshDeleteTargets.gone(204, 403))
    }
}
