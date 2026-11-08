package com.nostrvault.fips

import com.nostrvault.relay.HavenConfig
import org.junit.Assert.assertEquals
import org.junit.Test

/** Where the owner's new notes and media go over the mesh: the mobile vault and each Mac (Logen 2026-11-08). */
class MeshSendTargetsTest {
    private val mac = "npub1qgpqyqszqgpqyqszqgpqyqszqgpqyqszqgpqyqszqgpqyqszqgpq2yz0cn"
    private val kiosk = "npub1qvpsxqcrqvpsxqcrqvpsxqcrqvpsxqcrqvpsxqcrqvpsxqcrqvps0km4w3"
    private val phone = "npub1qyqszqgpqyqszqgpqyqszqgpqyqszqgpqyqszqgpqyqszqgpqyqs8j9gdm"

    private fun config(devices: List<FipsDevice>, peers: List<String> = devices.map { it.npub }, home: String? = null) =
        HavenConfig(fipsPeers = peers, homeVaultNpub = home, fipsMesh = FipsMeshSettings(devices = devices))

    /** Logen 2026-11-08: no per-device switches, and phones are not sent to, as on iPhone. */
    @Test
    fun `the mobile vault and each mac get everything, phones get nothing`() {
        val c = config(listOf(FipsDevice(mac, DeviceRole.MAC), FipsDevice(phone, DeviceRole.PHONE)), home = kiosk)
        assertEquals(listOf(MeshSendTarget(kiosk, DeviceRole.HOME_VAULT), MeshSendTarget(mac, DeviceRole.MAC)), MeshSendTargets.of(c))
        // The phone is still one of the owner's devices: Delete everywhere and own-devices sharing use this list.
        assertEquals(
            listOf(MeshSendTarget(kiosk, DeviceRole.HOME_VAULT), MeshSendTarget(mac, DeviceRole.MAC), MeshSendTarget(phone, DeviceRole.PHONE)),
            MeshSendTargets.ownDevices(c),
        )
    }

    @Test
    fun `only the mobile vault and macs are sent anything`() {
        assertEquals(listOf(DeviceRole.MAC, DeviceRole.HOME_VAULT), DeviceRole.entries.filter { MeshSendTargets.receivesSends(it) })
    }

    @Test
    fun `a mobile vault with no label is a target`() {
        assertEquals(listOf(MeshSendTarget(kiosk, DeviceRole.HOME_VAULT)), MeshSendTargets.of(config(emptyList(), peers = listOf(kiosk), home = kiosk)))
    }

    @Test
    fun `a mac that was removed from my devices is not sent to`() {
        // Its label can outlive it in the list; fipsPeers is what My Devices is.
        assertEquals(emptyList<MeshSendTarget>(), MeshSendTargets.of(config(listOf(FipsDevice(mac, DeviceRole.MAC)), peers = emptyList())))
    }

    @Test
    fun `a removed phone is not one of the owner's devices`() {
        assertEquals(emptyList<MeshSendTarget>(), MeshSendTargets.ownDevices(config(listOf(FipsDevice(phone, DeviceRole.PHONE)), peers = emptyList())))
    }

    @Test
    fun `a browser vault is never a target`() {
        assertEquals(emptyList<MeshSendTarget>(), MeshSendTargets.of(config(listOf(FipsDevice(phone, DeviceRole.BROWSER)))))
        assertEquals(emptyList<MeshSendTarget>(), MeshSendTargets.ownDevices(config(listOf(FipsDevice(phone, DeviceRole.BROWSER)))))
    }

    @Test
    fun `a phone is named as a phone, not as a home vault`() {
        assertEquals("Your other phone", MeshSendTargets.label(DeviceRole.PHONE))
        assertEquals("your other phone", MeshSendTargets.destination(DeviceRole.PHONE))
    }

    @Test
    fun `one lane that could not queue does not hold up the others`() {
        assertEquals(true to true, MeshSendTargets.afterQueueing(listOf(true, false)))  // drain the mobile vault, say "full"
        assertEquals(true to false, MeshSendTargets.afterQueueing(listOf(true, true)))
        assertEquals(false to true, MeshSendTargets.afterQueueing(listOf(false, false)))
    }
}
