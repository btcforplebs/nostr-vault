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
                MeshSendTarget(phone, DeviceRole.PHONE, notes = true, media = true),
            ),
            targets,
        )
    }

    @Test
    fun `the home vault follows its own send switches`() {
        // Its switches were drawn but the home vault always got notes and media (bug hunt 2026-11-05 #6).
        val targets = MeshSendTargets.of(
            config(listOf(FipsDevice(kiosk, DeviceRole.HOME_VAULT, sendNotes = true, sendMedia = false)), home = kiosk),
        )
        assertEquals(listOf(MeshSendTarget(kiosk, DeviceRole.HOME_VAULT, notes = true, media = false)), targets)
        val notesOff = MeshSendTargets.of(config(listOf(FipsDevice(kiosk, DeviceRole.PHONE, sendNotes = false)), home = kiosk))
        assertEquals(listOf(MeshSendTarget(kiosk, DeviceRole.HOME_VAULT, notes = false, media = true)), notesOff)
    }

    @Test
    fun `only roles that are sent anything have send switches`() {
        assertEquals(
            listOf(DeviceRole.MAC, DeviceRole.PHONE, DeviceRole.HOME_VAULT),
            DeviceRole.entries.filter { MeshSendTargets.receivesSends(it) },
        )
    }

    @Test
    fun `a home vault with no label gets everything`() {
        assertEquals(
            listOf(MeshSendTarget(kiosk, DeviceRole.HOME_VAULT, notes = true, media = true)),
            MeshSendTargets.of(config(emptyList(), peers = listOf(kiosk), home = kiosk)),
        )
    }

    @Test
    fun `a mac that was removed from my devices is not sent to`() {
        // Its label can outlive it in the list; fipsPeers is what My Devices is.
        assertEquals(emptyList<MeshSendTarget>(), MeshSendTargets.of(config(listOf(FipsDevice(mac, DeviceRole.MAC)), peers = emptyList())))
    }

    /** Logen 2026-11-05: every linked phone gets new photos and notes, with its own switches. */
    @Test
    fun `a linked phone is a target with its own switches`() {
        assertEquals(
            listOf(MeshSendTarget(phone, DeviceRole.PHONE, notes = false, media = true)),
            MeshSendTargets.of(config(listOf(FipsDevice(phone, DeviceRole.PHONE, sendNotes = false)))),
        )
        // Taken out of My Devices (not in fipsPeers): its label alone sends nothing.
        assertEquals(emptyList<MeshSendTarget>(), MeshSendTargets.of(config(listOf(FipsDevice(phone, DeviceRole.PHONE)), peers = emptyList())))
    }

    @Test
    fun `a browser vault is never a target`() {
        assertEquals(emptyList<MeshSendTarget>(), MeshSendTargets.of(config(listOf(FipsDevice(phone, DeviceRole.BROWSER)))))
    }

    @Test
    fun `a phone is named as a phone, not as a home vault`() {
        assertEquals("Your other phone", MeshSendTargets.label(DeviceRole.PHONE))
        assertEquals("your other phone", MeshSendTargets.destination(DeviceRole.PHONE))
    }

    @Test
    fun `one lane that could not queue does not hold up the others`() {
        assertEquals(true to true, MeshSendTargets.afterQueueing(listOf(true, false)))  // drain the home vault, say "full"
        assertEquals(true to false, MeshSendTargets.afterQueueing(listOf(true, true)))
        assertEquals(false to true, MeshSendTargets.afterQueueing(listOf(false, false)))
    }
}
