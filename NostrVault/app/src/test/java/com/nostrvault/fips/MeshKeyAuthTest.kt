package com.nostrvault.fips

import com.nostrvault.relay.HavenConfig
import kotlinx.serialization.json.Json
import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.jsonArray
import kotlinx.serialization.json.jsonObject
import kotlinx.serialization.json.jsonPrimitive
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

/** The mesh never uses the account key (contract §2, §2.1; Apple MeshKeyAuthTests, #1803). */
class MeshKeyAuthTest {
    // Real npubs: My Devices takes only valid ones.
    private val a = "npub1qyqszqgpqyqszqgpqyqszqgpqyqszqgpqyqszqgpqyqszqgpqyqs8j9gdm"
    private val b = "npub1qgpqyqszqgpqyqszqgpqyqszqgpqyqszqgpqyqszqgpqyqszqgpq2yz0cn"
    private val me = "npub1qvpsxqcrqvpsxqcrqvpsxqcrqvpsxqcrqvpsxqcrqvpsxqcrqvps0km4w3"
    private val sha = "AB".repeat(32)

    @Test
    fun `the start names A's mesh npub and no device`() {
        val tags = MeshKeyAuth.copyStartTags("http://127.0.0.1:4000/", a)!!
        assertEquals(listOf(listOf("u", "http://127.0.0.1:4000/copy/v2/start"), listOf("method", "POST"), listOf("p", a)), tags)
        assertFalse(tags.any { it.first() == "device" })
        assertNull(MeshKeyAuth.copyStartTags("http://127.0.0.1:4000", " "))
    }

    @Test
    fun `a blossom token has one t, an x per blob, a p per vault and the size`() {
        val tags = MeshKeyAuth.blossomTags(MeshKeyAuth.Verb.DELETE, listOf(sha, sha.lowercase()), listOf(a, b, a), nowS = 1000, size = 42)!!
        assertEquals(listOf("t", "delete"), tags.first())
        assertEquals(1, tags.count { it[0] == "t" })
        assertEquals(listOf(listOf("x", sha.lowercase())), tags.filter { it[0] == "x" })
        assertEquals(listOf(a, b), tags.filter { it[0] == "p" }.map { it[1] })
        assertEquals(listOf("size", "42"), tags.single { it[0] == "size" })
        assertEquals("1300", tags.single { it[0] == "expiration" }[1])
    }

    @Test
    fun `a blossom token lives five minutes at most`() {
        val long = MeshKeyAuth.blossomTags(MeshKeyAuth.Verb.UPLOAD, listOf(sha), listOf(a), nowS = 1000, lifetimeS = 3600)!!
        assertEquals("1300", long.single { it[0] == "expiration" }[1])
        val short = MeshKeyAuth.blossomTags(MeshKeyAuth.Verb.GET, listOf(sha), listOf(a), nowS = 1000, lifetimeS = 60)!!
        assertEquals("1060", short.single { it[0] == "expiration" }[1])
    }

    @Test
    fun `no blob or no vault is no token`() {
        assertNull(MeshKeyAuth.blossomTags(MeshKeyAuth.Verb.GET, emptyList(), listOf(a)))
        assertNull(MeshKeyAuth.blossomTags(MeshKeyAuth.Verb.GET, listOf(sha), listOf("  ")))
    }

    @Test
    fun `the paired set leaves this device out, lists each once and keeps roles`() {
        val json = MeshKeyAuth.deviceSet(
            me,
            listOf(MeshKeyAuth.Device(a, DeviceRole.MAC), MeshKeyAuth.Device(me, DeviceRole.PHONE), MeshKeyAuth.Device(a, DeviceRole.PHONE), MeshKeyAuth.Device(b, DeviceRole.HOME_VAULT)),
        )!!
        val o = Json.parseToJsonElement(json).jsonObject
        assertEquals(me, o["self"]!!.jsonPrimitive.content)
        val devices = o["devices"]!!.jsonArray.map { it as JsonObject }
        assertEquals(listOf(a to "mac", b to "home_vault"), devices.map { it["npub"]!!.jsonPrimitive.content to it["role"]!!.jsonPrimitive.content })
    }

    @Test
    fun `an empty set is still a set, and no mesh key is none`() {
        assertEquals("""{"devices":[],"self":"$me"}""", MeshKeyAuth.deviceSet(me, emptyList()))
        assertNull(MeshKeyAuth.deviceSet(null, listOf(MeshKeyAuth.Device(a, DeviceRole.MAC))))
        assertNull(MeshKeyAuth.deviceSet(" ", emptyList()))
    }

    @Test
    fun `the owner form is tried only on a 401 or 403 without the paired-set header`() {
        assertTrue(MeshKeyAuth.retriesWithOwnerForm(401, listOf("Content-Type")))
        assertTrue(MeshKeyAuth.retriesWithOwnerForm(403, emptyList()))
        assertFalse(MeshKeyAuth.retriesWithOwnerForm(401, listOf("X-Mesh-Devices")))
        assertFalse(MeshKeyAuth.retriesWithOwnerForm(403, listOf("x-mesh-devices")))
        assertFalse(MeshKeyAuth.retriesWithOwnerForm(404, emptyList()))
        assertFalse(MeshKeyAuth.retriesWithOwnerForm(500, emptyList()))
        assertFalse(MeshKeyAuth.retriesWithOwnerForm(200, emptyList()))
    }

    @Test
    fun `the set is the owner's devices with their roles`() {
        val other = "npub1qszqgpqyqszqgpqyqszqgpqyqszqgpqyqszqgpqyqszqgpqyqszq764t2k"
        val config = HavenConfig(
            ownerNpub = "npub1owner",
            fipsPeers = listOf(a, me, other),
            homeVaultNpub = b,
            fipsMesh = FipsMeshSettings(
                devices = listOf(FipsDevice(a, DeviceRole.MAC), FipsDevice(other, DeviceRole.PHONE, linkedBy = "npub1someoneelse")),
            ),
        )
        val devices = MeshDeviceSetSync.devices(config, me)
        // This device and another account's device are left out; the unlabelled home vault is the home vault.
        assertEquals(listOf(MeshKeyAuth.Device(a, DeviceRole.MAC), MeshKeyAuth.Device(b, DeviceRole.HOME_VAULT)), devices)
    }

    @Test
    fun `the signer signs the start and blossom tokens only`() {
        assertEquals(setOf(27235, 24242), MeshKeySigner.KINDS)
        var read = false
        val before = MeshKeySigner.readNsec
        MeshKeySigner.readNsec = { read = true; null }
        try {
            // A kind it does not sign never reads the key.
            assertNull(MeshKeySigner.authorization(1, "", emptyList()))
            assertNull(MeshKeySigner.authorization(MeshPairing.HELLO_KIND, "", emptyList()))
            assertFalse(read)
            // No mesh key: nothing signed (the engine makes the key, never this).
            assertNull(MeshKeySigner.authorization(24242, "", emptyList()))
            assertTrue(read)
        } finally {
            MeshKeySigner.readNsec = before
        }
    }
    @Test
    fun `a publish token has one t=publish, a p for the vault, no x, and lives five minutes at most`() {
        val tags = MeshKeyAuth.publishTags(a, nowS = 1000)!!
        assertEquals(listOf(listOf("t", "publish"), listOf("p", a), listOf("expiration", "1300")), tags)
        assertEquals(1, tags.count { it[0] == "t" })
        assertFalse(tags.any { it[0] == "x" })
        assertEquals("1300", MeshKeyAuth.publishTags(a, nowS = 1000, lifetimeS = 3600)!!.single { it[0] == "expiration" }[1])
        assertEquals("1060", MeshKeyAuth.publishTags(" $a ", nowS = 1000, lifetimeS = 60)!!.single { it[0] == "expiration" }[1])
        assertEquals(a, MeshKeyAuth.publishTags(" $a ", nowS = 1000)!!.single { it[0] == "p" }[1])
        // No vault named: the vault refuses it, so there is none.
        assertNull(MeshKeyAuth.publishTags(" ", nowS = 1000))
    }

    @Test
    fun `no mesh key signs no publish token`() {
        val before = MeshKeySigner.readNsec
        MeshKeySigner.readNsec = { null }
        try {
            assertNull(MeshKeySigner.publish(a))
        } finally {
            MeshKeySigner.readNsec = before
        }
    }
}
