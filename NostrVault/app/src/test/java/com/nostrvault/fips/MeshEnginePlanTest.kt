package com.nostrvault.fips

import com.nostrvault.relay.HavenConfig
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNotEquals
import org.junit.Assert.assertTrue
import org.junit.Test
import java.io.File

/** Checklist item 4 (Android): My Devices as the engine's allowlist, strangers to the door. */
class MeshEnginePlanTest {
    // Throwaway keys (0x01.. repeated), valid bech32.
    private val phone = "npub1qyqszqgpqyqszqgpqyqszqgpqyqszqgpqyqszqgpqyqszqgpqyqs8j9gdm"
    private val mac = "npub1qgpqyqszqgpqyqszqgpqyqszqgpqyqszqgpqyqszqgpqyqszqgpq2yz0cn"
    private val kiosk = "npub1qvpsxqcrqvpsxqcrqvpsxqcrqvpsxqcrqvpsxqcrqvpsxqcrqvps0km4w3"
    private val me = "npub1qszqgpqyqszqgpqyqszqgpqyqszqgpqyqszqgpqyqszqgpqyqszq764t2k"

    @Test
    fun `my devices and the home vault are the allowlist, and strangers get only the door`() {
        val config = HavenConfig(fipsPeers = listOf(phone, mac), homeVaultNpub = kiosk, relayPort = 4000)
        val options = MeshEnginePlan.options(config, ownNpub = me, maxServeBytes = 1)

        assertEquals(listOf(phone, mac, kiosk), options.ownDevices)
        assertEquals(config.meshPort, options.strangersPort)
        // A follow's vault is read through the seeds, no dial: it never gets this phone's address,
        // and ingress to it is not refused (ERR_NOT_OWN) as it was with own devices set.
        assertTrue(options.readAnyone)
        // Own devices reach the relay; the engine refuses the door and the relay being one port.
        val share = MeshEnginePlan.sharePort(config, options.ownDevices)
        assertEquals(4000, share)
        assertNotEquals(options.strangersPort, share)
    }

    @Test
    fun `with no devices the engine is still closed, and strangers still get the door`() {
        val config = HavenConfig(relayPort = 4000)
        val options = MeshEnginePlan.options(config, ownNpub = me, maxServeBytes = 1)

        assertEquals(emptyList<String>(), options.ownDevices)
        // read_anyone keeps own-devices mode on with an empty list: no one's offers are answered,
        // so the default install no longer gives its address away (Tron, #1030 F4).
        assertTrue(options.readAnyone)
        // Strangers reach the door through the seeds, as with devices listed; the relay is no one's.
        assertEquals(config.meshPort, options.strangersPort)
        val share = MeshEnginePlan.sharePort(config, options.ownDevices)
        assertEquals(4000, share)
        assertNotEquals(options.strangersPort, share)
    }

    @Test
    fun `the allowlist never holds this phone, a typo or a repeat`() {
        val typo = phone.dropLast(1) + "q"
        val config = HavenConfig(fipsPeers = listOf(" $mac ", me, typo, mac), homeVaultNpub = mac)

        assertEquals(listOf(mac), MeshEnginePlan.ownDevices(config, ownNpub = me))
    }

    @Test
    fun `the start options carry both fields under the library's names`() {
        val config = HavenConfig(fipsPeers = listOf(mac), relayPort = 4000)
        val json = kotlinx.serialization.json.Json.encodeToString(FipsStartOptions.serializer(), MeshEnginePlan.options(config, null, 1))

        assertTrue(json, json.contains("\"own_devices\":[\"$mac\"]"))
        assertTrue(json, json.contains("\"strangers_port\":4001"))
        assertTrue(json, json.contains("\"read_anyone\":true"))
    }

    /**
     * Restart after a reboot: the boot receiver starts the relay service, and the service brings
     * the mesh back once the relay answers. Source-level, since neither runs without a device.
     */
    @Test
    fun `the relay service restores the mesh once the relay is up`() {
        val startup = File("src/main/java/com/nostrvault/relay/RelayForegroundServiceStartup.kt").readText()
        val up = startup.indexOf("lifecycleState = LifecycleState.RUNNING")
        assertTrue("relay success path not found", up > 0)
        assertTrue("restoreMesh() must follow the relay coming up", startup.indexOf("restoreMesh()", up) > up)

        val service = File("src/main/java/com/nostrvault/relay/RelayForegroundService.kt").readText()
        assertTrue(service.contains("fipsMeshManager()") && service.contains(".restoreIfEnabled(serviceScope)"))
    }
}
