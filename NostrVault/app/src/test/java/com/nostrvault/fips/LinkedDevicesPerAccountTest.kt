package com.nostrvault.fips

import com.nostrvault.relay.HavenConfig
import com.nostrvault.relay.MacSync
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Test

/**
 * Bug hunt 2026-11-05 #4: a device linked while an added account was active got the owner's posts. Linked devices
 * belong to the account that linked them (Logen 2026-11-05).
 */
class LinkedDevicesPerAccountTest {
    private val owner = "npub1sg6plzptd64u62a878hep2kev88swjh3tw00gjsfl8f237lmu63q0uf63m"
    private val other = "npub180cvv07tjdrrgpa0j7j7tmnyl2yr6yr7l8j4s3evf6u64th6gkwsyjh6w6"
    private val mac = "npub1qgpqyqszqgpqyqszqgpqyqszqgpqyqszqgpqyqszqgpqyqszqgpq2yz0cn"
    private val othersMac = "npub1qvpsxqcrqvpsxqcrqvpsxqcrqvpsxqcrqvpsxqcrqvpsxqcrqvps0km4w3"
    private val phone = "npub1qyqszqgpqyqszqgpqyqszqgpqyqszqgpqyqszqgpqyqszqgpqyqs8j9gdm"

    private fun config(devices: List<FipsDevice>, home: String? = null) =
        HavenConfig(ownerNpub = owner, fipsPeers = devices.map { it.npub }, homeVaultNpub = home, fipsMesh = FipsMeshSettings(devices = devices))

    @Test
    fun `another account's mac gets none of the owner's posts`() {
        val targets = MeshSendTargets.of(
            config(listOf(FipsDevice(mac, DeviceRole.MAC, linkedBy = owner), FipsDevice(othersMac, DeviceRole.MAC, linkedBy = other))),
        )
        assertEquals(listOf(mac), targets.map { it.npub })
    }

    @Test
    fun `devices from before keep going to the owner`() {
        assertEquals(listOf(mac), MeshSendTargets.of(config(listOf(FipsDevice(mac, DeviceRole.MAC)))).map { it.npub })
    }

    @Test
    fun `another account linking a home vault never takes the owner's home vault place`() {
        val before = listOf(FipsDevice(mac, DeviceRole.HOME_VAULT))
        val change = MyDevicesRules.add(
            listOf(mac), mac, before, ownNpub = phone, npub = othersMac, role = DeviceRole.HOME_VAULT, name = "Their box",
            linkedBy = other, ownerNpub = owner,
        )!!
        assertEquals(mac, change.homeVault)
        assertEquals(other, change.labels.first { it.npub == othersMac }.linkedBy)
        // It still lists as a home vault (that account's), not as a phone.
        val listed = MyDevicesRules.list(change.peers, change.homeVault, change.labels, emptyList(), owner)
        assertEquals(DeviceRole.HOME_VAULT, listed.first { it.npub == othersMac }.role)
        // And the owner's posts keep going to the owner's home vault only.
        val cfg = HavenConfig(ownerNpub = owner, fipsPeers = change.peers, homeVaultNpub = change.homeVault, fipsMesh = FipsMeshSettings(devices = change.labels))
        assertEquals(listOf(mac), MeshSendTargets.of(cfg).map { it.npub })
    }

    @Test
    fun `the owner linking keeps today's behaviour`() {
        val change = MyDevicesRules.add(emptyList(), null, emptyList(), phone, mac, DeviceRole.HOME_VAULT, "Box", linkedBy = owner, ownerNpub = owner)!!
        assertEquals(mac, change.homeVault)
        assertEquals("", change.labels.single().linkedBy)
    }

    @Test
    fun `a home vault label from another account is not sent the owner's posts`() {
        val cfg = config(listOf(FipsDevice(othersMac, DeviceRole.HOME_VAULT, linkedBy = other)), home = othersMac)
        assertEquals(emptyList<MeshSendTarget>(), MeshSendTargets.of(cfg))
    }

    @Test
    fun `only the owner's mac fills the owner's vault`() {
        assertNull(MacSync.macMeshNpub(config(listOf(FipsDevice(othersMac, DeviceRole.MAC, linkedBy = other)))))
        assertEquals(mac, MacSync.macMeshNpub(config(listOf(FipsDevice(othersMac, DeviceRole.MAC, linkedBy = other), FipsDevice(mac, DeviceRole.MAC)))))
    }

    @Test
    fun `another account's device is not on the engine allowlist and is not dialed`() {
        val cfg = config(listOf(FipsDevice(mac, DeviceRole.MAC), FipsDevice(othersMac, DeviceRole.MAC, linkedBy = other)))
        val options = MeshEnginePlan.options(cfg, ownNpub = phone, maxServeBytes = 1)
        assertEquals(listOf(mac), options.ownDevices)
        assertEquals(listOf(mac), options.peers)
    }

    @Test
    fun `a device the owner linked while active stays on the allowlist`() {
        val cfg = config(listOf(FipsDevice(mac, DeviceRole.MAC, linkedBy = owner)))
        assertEquals(listOf(mac), MeshEnginePlan.ownDevices(cfg, ownNpub = phone))
    }
}
