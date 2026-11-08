package com.nostrvault.fips

import com.nostrvault.relay.HavenConfig
import org.junit.Assert.assertEquals
import org.junit.Test

/** Media Servers › Your Vaults (Logen 2026-11-08): mobile and desktop vaults only, listed only by the owner's choice. */
class MediaServerVaultsTest {
    private val mac = "npub1qgpqyqszqgpqyqszqgpqyqszqgpqyqszqgpqyqszqgpqyqszqgpq2yz0cn"
    private val kiosk = "npub1qvpsxqcrqvpsxqcrqvpsxqcrqvpsxqcrqvpsxqcrqvpsxqcrqvps0km4w3"
    private val phone = "npub1qyqszqgpqyqszqgpqyqszqgpqyqszqgpqyqszqgpqyqszqgpqyqs8j9gdm"
    private val box = "npub1" + "t".repeat(58)

    private val linked = HavenConfig(
        fipsPeers = listOf(mac, phone, kiosk),
        homeVaultNpub = kiosk,
        fipsMesh = FipsMeshSettings(devices = listOf(
            FipsDevice(mac, DeviceRole.MAC, name = "Studio Mac"), FipsDevice(phone, DeviceRole.PHONE), FipsDevice(kiosk, DeviceRole.HOME_VAULT),
        )),
    )

    @Test fun `mobile and desktop vaults are offered, never a phone`() {
        assertEquals(
            listOf(
                MediaServerVault(kiosk, "Mobile vault", "Mobile vault", listed = false),
                MediaServerVault(mac, "Studio Mac", "Desktop vault", listed = false),
            ),
            MediaServerVaults.rows(linked, published = listOf("https://a.example")),
        )
    }

    @Test fun `listed comes from the published list and the owner's pending choice`() {
        val rows = MediaServerVaults.rows(linked, listOf("https://a.example", "fipsmesh://$mac/"))
        assertEquals(listOf(false, true), rows.map { it.listed })
        val added = MediaServerVaults.choose(linked, kiosk, list = true)
        assertEquals(listOf(kiosk), added.serverListAddMesh)
        assertEquals(listOf(true, true), MediaServerVaults.rows(added, listOf("fipsmesh://$mac/")).map { it.listed })
        val takenOff = MediaServerVaults.choose(added, mac, list = false)
        assertEquals(listOf(mac), takenOff.serverListDropMesh)
        assertEquals(listOf(true, false), MediaServerVaults.rows(takenOff, listOf("fipsmesh://$mac/")).map { it.listed })
        // Adding it back undoes the take-off.
        assertEquals(emptyList<String>(), MediaServerVaults.choose(takenOff, mac, list = true).serverListDropMesh)
    }

    @Test fun `a listed vault this phone has no device for can be taken off, a listed phone stays hidden`() {
        val rows = MediaServerVaults.rows(linked, listOf("https://a.example", "fipsmesh://$box/", "fipsmesh://$phone/"))
        assertEquals(listOf(kiosk, mac, box), rows.map { it.npub })
        assertEquals(MediaServerVault(box, "npub1ttttt…tttt", MediaServerVaults.UNKNOWN, listed = true), rows.last())
    }

    @Test fun `another account's devices are not offered`() {
        val other = linked.copy(ownerNpub = "npub1" + "o".repeat(58), fipsMesh = FipsMeshSettings(devices = listOf(
            FipsDevice(mac, DeviceRole.MAC, linkedBy = "npub1" + "x".repeat(58)),
        )), homeVaultNpub = null)
        assertEquals(emptyList<MediaServerVault>(), MediaServerVaults.rows(other, emptyList()))
    }
}
