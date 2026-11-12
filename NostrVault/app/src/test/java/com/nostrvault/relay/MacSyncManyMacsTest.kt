package com.nostrvault.relay

import com.nostrvault.fips.DeviceRole
import com.nostrvault.fips.FipsDevice
import com.nostrvault.fips.FipsMeshSettings
import org.junit.Assert.assertEquals
import org.junit.Test

/** Multi-Mac rules §1: every Mac of the owner's, not only the first (iOS MultiMacLogicTests). */
class MacSyncManyMacsTest {
    private val macA = "npub1qszqgpqyqszqgpqyqszqgpqyqszqgpqyqszqgpqyqszqgpqyqszq764t2k"
    private val macB = "npub1q5zs2pg9q5zs2pg9q5zs2pg9q5zs2pg9q5zs2pg9q5zs2pg9q5zsmgv3u5"
    private val box = "npub1qcrqvpsxqcrqvpsxqcrqvpsxqcrqvpsxqcrqvpsxqcrqvpsxqcrqk7tkfu"
    private val phone = "npub1qurswpc8qurswpc8qurswpc8qurswpc8qurswpc8qurswpc8qursnvjvl7"
    private val owner = "npub1owner"

    private fun config(devices: List<FipsDevice>, typed: String = "") = HavenConfig(
        ownerNpub = owner, macRelayURL = typed, fipsPeers = devices.map { it.npub },
        fipsMesh = FipsMeshSettings(devices = devices),
    )

    @Test
    fun `every mac and box is listed, the first one first, phones never`() {
        val c = config(listOf(FipsDevice(macA, DeviceRole.MAC), FipsDevice(phone), FipsDevice(macB, DeviceRole.MAC), FipsDevice(box, DeviceRole.MAC)))
        assertEquals(listOf(macA, macB, box), MacSync.macMeshNpubs(c))
    }

    @Test
    fun `a mac typed in the field comes first and is listed once`() {
        val c = config(listOf(FipsDevice(macA, DeviceRole.MAC), FipsDevice(macB, DeviceRole.MAC)), typed = macB)
        assertEquals(listOf(macB, macA), MacSync.macMeshNpubs(c))
    }

    @Test
    fun `this device and another account's mac are left out`() {
        val c = config(listOf(FipsDevice(macA, DeviceRole.MAC), FipsDevice(macB, DeviceRole.MAC, linkedBy = "npub1someoneelse")))
        assertEquals(emptyList<String>(), MacSync.macMeshNpubs(c, ownNpub = macA))
    }

    @Test
    fun `no macs gives an empty list`() {
        assertEquals(emptyList<String>(), MacSync.macMeshNpubs(config(listOf(FipsDevice(phone)))))
    }

    @Test
    fun `an entry saved before domains still reads, and a domain round-trips`() {
        val json = kotlinx.serialization.json.Json { ignoreUnknownKeys = true }
        val old = json.decodeFromString(FipsDevice.serializer(), """{"npub":"$macA"}""")
        assertEquals("", old.domain)
        val back = json.decodeFromString(FipsDevice.serializer(), json.encodeToString(FipsDevice.serializer(), FipsDevice(macA, DeviceRole.MAC, domain = "a.example.com")))
        assertEquals("a.example.com", back.domain)
    }
}
