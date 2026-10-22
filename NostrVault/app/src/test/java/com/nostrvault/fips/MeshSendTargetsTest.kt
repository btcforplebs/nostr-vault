package com.nostrvault.fips

import com.nostrvault.relay.HavenConfig
import org.junit.Assert.assertEquals
import org.junit.Test

/** Checklist item 4 (Android): a device added as "Vault on Mac" gets notes and media, as the home vault does. */
class MeshSendTargetsTest {
    private val mac = "npub1qgpqyqszqgpqyqszqgpqyqszqgpqyqszqgpqyqszqgpqyqszqgpq2yz0cn"
    private val kiosk = "npub1qvpsxqcrqvpsxqcrqvpsxqcrqvpsxqcrqvpsxqcrqvpsxqcrqvps0km4w3"
    private val phone = "npub1qyqszqgpqyqszqgpqyqszqgpqyqszqgpqyqszqgpqyqszqgpqyqs8j9gdm"

    private fun config(devices: List<FipsDevice>, peers: List<String> = devices.map { it.npub }, home: String? = null) =
        HavenConfig(fipsPeers = peers, homeVaultNpub = home, fipsMesh = FipsMeshSettings(devices = devices))

    @Test
    fun `a mac in my devices is a target, with its own switches`() {
        val targets = MeshSendTargets.of(
            config(listOf(FipsDevice(mac, DeviceRole.MAC, sendNotes = true, sendMedia = false), FipsDevice(phone, DeviceRole.PHONE)), home = kiosk),
        )
        assertEquals(
            listOf(
                MeshSendTarget(kiosk, DeviceRole.HOME_VAULT, notes = true, media = true),
                MeshSendTarget(mac, DeviceRole.MAC, notes = true, media = false),
            ),
            targets,
        )
    }

    @Test
    fun `a mac that was removed from my devices is not sent to`() {
        // Its label can outlive it in the list; fipsPeers is what My Devices is.
        assertEquals(emptyList<MeshSendTarget>(), MeshSendTargets.of(config(listOf(FipsDevice(mac, DeviceRole.MAC)), peers = emptyList())))
    }

    @Test
    fun `a phone is never a target`() {
        assertEquals(emptyList<MeshSendTarget>(), MeshSendTargets.of(config(listOf(FipsDevice(phone, DeviceRole.PHONE)))))
    }
}
