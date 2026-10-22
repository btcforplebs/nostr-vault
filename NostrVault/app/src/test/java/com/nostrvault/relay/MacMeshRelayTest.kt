package com.nostrvault.relay

import com.nostrvault.fips.DeviceRole
import com.nostrvault.fips.FipsBridge
import com.nostrvault.fips.FipsDevice
import com.nostrvault.fips.FipsIngress
import com.nostrvault.fips.FipsMeshSettings
import org.junit.After
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Test
import java.io.File

/** A Mac given as a mesh npub reaches the relay through FIPS (iOS RelayProcessManager+Start.swift:96). */
class MacMeshRelayTest {

    private val mac = "npub15ltk3g7wjmt0sjqk78cjv4mtttmy8ffyy9g7hg7spxwdz28wr2wszsrurl"
    private val other = "npub12fuf7setehcxg6dvdl2muj5dmk9c7kjmhcvexd0ndtskanfzjpns76048p"
    private val token = "0123456789abcdef0123456789abcdef"
    private val base = "http://127.0.0.1:41234/$token"
    private val ws = "ws://127.0.0.1:41234/$token"
    private val dir = File("/tmp/x")

    private val dialed = mutableListOf<String>()
    private fun reaches(url: String?, error: Int = 0): (String) -> FipsIngress = { npub ->
        dialed += npub
        FipsIngress(url = url, error = error)
    }

    @After fun reset() {
        RelayConfiguration.macMeshRelay = null
    }

    @Test fun meshNpubInTheMacFieldStartsTheRelayWithItsDialedAddress() {
        val config = HavenConfig(macRelayURL = "nostr:$mac", fipsMeshEnabled = true)
        val env = RelayConfiguration.launchInputs(config, dir, reaches(base)).env
        assertEquals(ws, env["MAC_RELAY_URL"])
        assertEquals(listOf(mac), dialed)
        // The Sync section matches the status file against the same address.
        assertEquals(ws, MacSync.macRelayURL(config))
    }

    @Test fun aVaultOnMacDeviceIsDialedLikeATypedNpub() {
        val config = HavenConfig(
            fipsMeshEnabled = true,
            fipsPeers = listOf(other, mac),
            fipsMesh = FipsMeshSettings(devices = listOf(FipsDevice(npub = other), FipsDevice(npub = mac, role = DeviceRole.MAC))),
        )
        assertEquals(mac, MacSync.macMeshNpub(config))
        assertEquals(ws, RelayConfiguration.launchInputs(config, dir, reaches(base)).env["MAC_RELAY_URL"])
    }

    @Test fun aMacRoleOffTheAllowlistOrMarkedHomeVaultIsNotTheMac() {
        val labels = FipsMeshSettings(devices = listOf(FipsDevice(npub = mac, role = DeviceRole.MAC)))
        assertNull(MacSync.macMeshNpub(HavenConfig(fipsMeshEnabled = true, fipsMesh = labels)))
        assertNull(MacSync.macMeshNpub(HavenConfig(fipsMeshEnabled = true, fipsPeers = listOf(mac), homeVaultNpub = mac, fipsMesh = labels)))
    }

    @Test fun aMacWithAURLKeepsItAndIsNeverDialed() {
        val config = HavenConfig(
            macRelayURL = "mac.example.com",
            fipsMeshEnabled = true,
            fipsPeers = listOf(mac),
            fipsMesh = FipsMeshSettings(devices = listOf(FipsDevice(npub = mac, role = DeviceRole.MAC))),
        )
        assertEquals("wss://mac.example.com", RelayConfiguration.launchInputs(config, dir, reaches(base)).env["MAC_RELAY_URL"])
        assertEquals(emptyList<String>(), dialed)
    }

    @Test fun aFailedDialStartsTheRelayWithoutTheMac() {
        val config = HavenConfig(macRelayURL = mac, fipsMeshEnabled = true)
        RelayConfiguration.macMeshRelay = RelayConfiguration.MacMeshRelay(mac, ws)
        val env = RelayConfiguration.launchInputs(config, dir, reaches(null, FipsBridge.ERR_START)).env
        // Not the npub as a host (wss://npub1…), and not last session's address.
        assertEquals("", env["MAC_RELAY_URL"])
        assertNull(RelayConfiguration.macMeshRelay)
    }

    @Test fun meshOffNeverDials() {
        val config = HavenConfig(macRelayURL = mac, fipsMeshEnabled = false)
        assertEquals("", RelayConfiguration.launchInputs(config, dir, reaches(base)).env["MAC_RELAY_URL"])
        assertEquals(emptyList<String>(), dialed)
    }

    @Test fun waitsForTheMeshNodeTheAppStartsAfterTheRelay() {
        val config = HavenConfig(macRelayURL = mac, fipsMeshEnabled = true)
        var calls = 0
        val paused = mutableListOf<Long>()
        val relay = RelayConfiguration.resolveMacMeshRelay(config, dial = {
            calls++
            if (calls < 3) FipsIngress(error = FipsBridge.ERR_NOT_RUNNING) else FipsIngress(url = base)
        }, pause = { paused += it })
        assertEquals(RelayConfiguration.MacMeshRelay(mac, ws), relay)
        assertEquals(3, calls)
        assertEquals(2, paused.size)
    }

    @Test fun givesUpOnANodeThatNeverStarts() {
        val config = HavenConfig(macRelayURL = mac, fipsMeshEnabled = true)
        var waited = 0L
        val relay = RelayConfiguration.resolveMacMeshRelay(config, dial = { FipsIngress(error = FipsBridge.ERR_NOT_RUNNING) }, pause = { waited += it })
        assertNull(relay)
        assertEquals(RelayConfiguration.MESH_NODE_WAIT_MS, waited)
    }

    @Test fun anotherMacsAddressIsNotThisOnes() {
        val config = HavenConfig(macRelayURL = mac)
        assertEquals("", MacSync.macRelayURL(config, RelayConfiguration.MacMeshRelay(other, ws)))
        assertEquals(ws, MacSync.macRelayURL(config, RelayConfiguration.MacMeshRelay(mac, ws)))
    }

    @Test fun ingressBaseBecomesAWebsocketAddress() {
        assertEquals(ws, RelayConfiguration.meshWebsocketURL(base))
        assertEquals("wss://h.example/x", RelayConfiguration.meshWebsocketURL("https://h.example/x"))
        assertNull(RelayConfiguration.meshWebsocketURL("ws://127.0.0.1:1/x"))
        assertNull(RelayConfiguration.meshWebsocketURL("not a url"))
    }
}
