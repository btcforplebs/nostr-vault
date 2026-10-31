package com.nostrvault.fips

import com.nostrvault.relay.HavenConfig
import kotlinx.serialization.json.Json
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

/** FIPS Mesh → My Devices: one list both ways (the allowlist), the home vault one of its roles. */
class MyDevicesRulesTest {
    // Real npubs (random test keys, nobody's), so the bech32 checksum holds.
    private val mac = "npub1k3rr0umjwn65yz8en8s3cmpxya72k7swcuj98anxkvhq26qmnrkqduad7c"
    private val kiosk = "npub1qqwvy6rnfsfuehqcqjkhcejhdvxp37kj8enxm0h0l2sc73q8ex9q9emf0g"
    private val phone = "npub197rquuc9m0dx7ccvv46tz4ayzm7f7j4fy8pm6yvhfej50mt7z65s7ga2vz"
    private val me = "npub1v9aafscx5r7l5zk7h73z8wyhgx9uys2mflgvl3m20pzflthazceqnma53d"

    @Test fun `the list is the allowlist plus a home vault not on it, with names and roles`() {
        val labels = listOf(FipsDevice(mac, DeviceRole.MAC, "MacBook"), FipsDevice(phone, DeviceRole.HOME_VAULT, "stale role"))
        val list = MyDevicesRules.list(peers = listOf(mac, phone), homeVault = kiosk, labels = labels, connected = listOf(mac))
        assertEquals(listOf(mac, phone, kiosk), list.map { it.npub })
        assertEquals(listOf(DeviceRole.MAC, DeviceRole.PHONE, DeviceRole.HOME_VAULT), list.map { it.role })
        assertEquals("MacBook", list[0].title)
        assertTrue(list[0].inReach); assertFalse(list[2].inReach)
        assertEquals("a device with no name goes by its role, as on iPhone", "Home vault · new posts", list[2].title)
    }

    @Test fun `status line counts devices in reach`() {
        val list = MyDevicesRules.list(listOf(mac, phone, kiosk, me), null, emptyList(), listOf(mac, phone, kiosk))
        assertEquals("On · 3 of 4 devices in reach", MyDevicesRules.statusLine(true, list))
        assertEquals("On · 0 of 1 device in reach", MyDevicesRules.statusLine(true, list.take(1).map { it.copy(inReach = false) }))
        assertEquals("On", MyDevicesRules.statusLine(true, emptyList()))
        assertEquals("Off", MyDevicesRules.statusLine(false, list))
    }

    @Test fun `adding lets the device in, and a home vault takes over the role`() {
        val first = MyDevicesRules.add(emptyList(), null, emptyList(), me, kiosk, DeviceRole.HOME_VAULT, " Kitchen ")!!
        assertEquals(listOf(kiosk), first.peers)
        assertEquals(kiosk, first.homeVault)
        assertEquals("Kitchen", first.labels.single().name)
        assertEquals("adding a device is not seeing it", 0L, first.labels.single().lastSeen)
        // A second home vault: the first stays in the list, as a phone.
        val second = MyDevicesRules.add(first.peers, first.homeVault, first.labels, me, phone, DeviceRole.HOME_VAULT, "")!!
        assertEquals(listOf(kiosk, phone), second.peers)
        assertEquals(phone, second.homeVault)
        assertEquals(DeviceRole.PHONE, second.labels.first { it.npub == kiosk }.role)
        // A Mac leaves the home vault alone.
        assertEquals(phone, MyDevicesRules.add(second.peers, second.homeVault, second.labels, me, mac, DeviceRole.MAC, "")!!.homeVault)
    }

    @Test fun `re-adding the home vault as something else ends its home vault role`() {
        val c = MyDevicesRules.add(listOf(kiosk), kiosk, listOf(FipsDevice(kiosk, DeviceRole.HOME_VAULT)), me, kiosk, DeviceRole.PHONE, "")!!
        assertNull(c.homeVault)
        assertEquals(listOf(kiosk), c.peers)
        assertEquals(DeviceRole.PHONE, c.labels.single().role)
    }

    @Test fun `this phone's own address and non-addresses are refused`() {
        assertNull(MyDevicesRules.add(emptyList(), null, emptyList(), me, me, DeviceRole.PHONE, ""))
        assertNull(MyDevicesRules.add(emptyList(), null, emptyList(), me, "npub1short", DeviceRole.PHONE, ""))
        assertNull(MyDevicesRules.add(emptyList(), null, emptyList(), me, "npub1" + "b".repeat(58), DeviceRole.PHONE, ""))
        // One character off: right shape, broken checksum. It would be a dead allowlist entry.
        val typo = mac.dropLast(1) + (if (mac.last() == 'q') 'p' else 'q')
        assertFalse(MyDevicesRules.isMeshNpub(typo))
        assertTrue(MyDevicesRules.isMeshNpub(mac))
        assertNull(MyDevicesRules.add(emptyList(), null, emptyList(), me, typo, DeviceRole.PHONE, ""))
    }

    @Test fun `removing takes it out of the allowlist and ends a home vault`() {
        val c = MyDevicesRules.remove(listOf(mac, kiosk), kiosk, listOf(FipsDevice(kiosk, DeviceRole.HOME_VAULT), FipsDevice(mac, DeviceRole.MAC)), kiosk)
        assertEquals(listOf(mac), c.peers)
        assertNull(c.homeVault)
        assertEquals(listOf(mac), c.labels.map { it.npub })
        // A home vault that was never on the allowlist goes too.
        assertNull(MyDevicesRules.remove(emptyList(), kiosk, emptyList(), kiosk).homeVault)
    }

    @Test fun `last seen is noted for devices in reach and read back plainly`() {
        val labels = listOf(FipsDevice(mac, DeviceRole.MAC, lastSeen = 10))
        val seen = MyDevicesRules.seen(labels, listOf(mac, phone), connected = listOf(mac, phone), now = 500)
        assertEquals(listOf(500L, 500L), seen.map { it.lastSeen })
        assertEquals(DeviceRole.MAC, seen[0].role)
        assertTrue(MyDevicesRules.seen(labels, listOf(mac), connected = emptyList(), now = 500) === labels)
        assertEquals("Now", MyDevicesRules.lastSeenText(0, true, 1000))
        assertEquals("Never", MyDevicesRules.lastSeenText(0, false, 1000))
        assertEquals("2 h ago", MyDevicesRules.lastSeenText(1000, false, 1000 + 2 * 3600 + 5))
        assertEquals("5 min ago", MyDevicesRules.lastSeenText(1000, false, 1300))
    }

    @Test fun `the engine starts with the iPhone's three finder relays unless the user picked others`() {
        assertEquals(listOf("wss://relay.nostr.net", "wss://nostr.bitcoiner.social", "wss://relay.btcforplebs.com"), FipsMeshSettings().engineFinderRelays)
        assertEquals(listOf("wss://relay.example"), FipsMeshSettings(finderRelays = listOf("wss://relay.example")).engineFinderRelays)
        assertEquals("Android never joined the public seeds: None until the user picks Public", FipsMeshSettings.MIDDLE_NONE, FipsMeshSettings().middleServer)
    }

    @Test fun `finder relays must be wss hosts`() {
        assertTrue(MyDevicesRules.isFinderRelay("wss://relay.nostr.net"))
        assertTrue(MyDevicesRules.isFinderRelay(" wss://relay.example:4443/path "))
        assertFalse(MyDevicesRules.isFinderRelay("ws://relay.example"))
        assertFalse(MyDevicesRules.isFinderRelay("https://relay.example"))
        assertFalse(MyDevicesRules.isFinderRelay("wss://a\"]\n dm_relays"))
    }

    @Test fun `an older config without fipsMesh reads as today's defaults, and a new one round-trips`() {
        val json = Json { ignoreUnknownKeys = true }
        val old = json.decodeFromString(HavenConfig.serializer(), """{"fipsPeers":["$mac"],"homeVaultNpub":"$kiosk"}""")
        assertEquals(FipsMeshSettings(), old.fipsMesh)
        assertEquals(FipsMeshSettings.PHOTOS_PUBLIC, old.fipsMesh.photosGoTo)
        val set = old.copy(fipsMesh = FipsMeshSettings(devices = listOf(FipsDevice(mac, DeviceRole.MAC, "Mac")), photosGoTo = FipsMeshSettings.PHOTOS_BOTH,
            finderRelays = listOf("wss://relay.example"), middleServer = FipsMeshSettings.MIDDLE_PUBLIC))
        assertEquals(set, json.decodeFromString(HavenConfig.serializer(), json.encodeToString(HavenConfig.serializer(), set)))
    }
}
