package com.nostrvault.fips

import com.nostrvault.fips.CopySettingsSync.Step
import com.nostrvault.fips.MeshCopyFixtures.obj
import com.nostrvault.relay.DesktopVault
import com.nostrvault.relay.DesktopVaultsRules
import com.nostrvault.relay.HavenConfig
import com.nostrvault.relay.desktopVaultsInEffect
import kotlinx.serialization.json.JsonArray
import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.JsonPrimitive
import kotlinx.serialization.json.jsonArray
import kotlinx.serialization.json.jsonPrimitive
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

/**
 * Tron's review of #2521 (Desktop Vaults P10): what this device can't hold is carried, an unwritten edit here survives
 * a foreign file, and an empty Vault list is left out for older engines. iOS CopyVaultsReviewTests.
 */
class CopyVaultsReviewTest {
    private val now = 1767000300L

    private fun npubs(): Pair<String, String> {
        val clean = MeshCopyFixtures.json("settings-refuse-cases.json")["cases"]!!.jsonArray.map { it.obj() }
            .first { it["name"]!!.jsonPrimitive.content == "vault list, clean" }
        val l = clean["settings"]!!.obj()["keys"]!!.obj()["desktop_vaults"]!!.jsonArray.map { it.obj() }
        return l[0]["meshNpub"]!!.jsonPrimitive.content to l[1]["meshNpub"]!!.jsonPrimitive.content
    }

    private fun entry(id: String, mesh: String? = null, https: String? = null, order: Int = 0, at: Long = 1767000000) =
        JsonObject(buildMap {
            put("id", JsonPrimitive(id)); put("name", JsonPrimitive("")); put("kind", JsonPrimitive("mac"))
            put("order", JsonPrimitive(order)); put("updatedAt", JsonPrimitive(at))
            mesh?.let { put("meshNpub", JsonPrimitive(it)) }
            https?.let { put("httpsURL", JsonPrimitive(it)) }
        })

    private fun out(c: HavenConfig, previous: List<JsonObject>): Map<String, JsonObject> =
        (CopySettings.keys(c, JsonArray(previous), ownNpub = null, nowS = now)["desktop_vaults"] as JsonArray)
            .map { it.obj() }.associateBy { it["id"]!!.jsonPrimitive.content }

    /** A Mac linked by another account, and a phone: followingDevices drops both addresses, so both are carried. */
    @Test
    fun `an address paired here that this device can't hold is carried, never stripped or deleted`() {
        val (mac, box) = npubs()
        for (device in listOf(
            FipsDevice(npub = box, role = DeviceRole.PHONE, name = "Phone"),
            FipsDevice(npub = box, role = DeviceRole.MAC, name = "Their Mac", linkedBy = mac),
        )) {
            val c = HavenConfig(
                ownerNpub = "npub1owner",
                fipsMesh = FipsMeshSettings(devices = listOf(device)),
                desktopVaults = listOf(DesktopVault(id = "https:box.example", httpsURL = "https://box.example")),
            )
            assertTrue("control (${device.role}): dropped here", c.desktopVaultsInEffect(null).all { it.meshNpub == null })
            val byId = out(c, listOf(entry("mesh:$box", mesh = box), entry("https:box.example", mesh = box, https = "https://box.example", order = 1)))
            assertNull("${device.role}: tombstoned", byId["mesh:$box"]!!["deletedAt"])
            assertEquals("${device.role}: stripped", box, byId["https:box.example"]!!["meshNpub"]?.jsonPrimitive?.content)
        }
    }

    @Test
    fun `holdable is what followingDevices keeps`() {
        val (mac, box) = npubs()
        val devices = listOf(FipsDevice(npub = mac, role = DeviceRole.MAC), FipsDevice(npub = box, role = DeviceRole.PHONE))
        assertEquals(setOf(mac), DesktopVaultsRules.holdableMeshNpubs(devices, "", null))
        assertEquals(emptySet<String>(), DesktopVaultsRules.holdableMeshNpubs(devices, "", mac))
    }

    /**
     * The engine stored a peer's file (zaps_only changed there) while new_posts_pill changed here and wasn't written:
     * only the peer's change is taken in, and the edit is written over it.
     */
    @Test
    fun `a foreign file takes in only what changed there while an edit here is unwritten`() {
        val before = HavenConfig(zapsOnlyMode = false, showNewPostsPill = true,
            desktopVaults = listOf(DesktopVault(id = "https:a.example", httpsURL = "https://a.example")))
        val base = CopySettings.keys(before, ownNpub = null, nowS = now)
        val b = entry("https:b.example", https = "https://b.example", order = 1, at = now)
        val theirs = JsonObject(base + mapOf("zaps_only" to JsonPrimitive(true),
            "desktop_vaults" to JsonArray((base["desktop_vaults"] as JsonArray) + b)))
        val edited = before.copy(showNewPostsPill = false)
        val current = CopySettings.keys(edited, ownNpub = null, nowS = now)
        val s = CopySettingsSync.step(current, CopySettings.file(theirs, 200), base.toString(), 100, now, setupDone = true)
        assertTrue(s is Step.Apply)
        s as Step.Apply
        assertEquals(now, s.rewriteAt)
        val only = s.only!!
        assertEquals(setOf("zaps_only", "desktop_vaults"), only.keys)
        assertEquals(listOf("https:b.example"), (only["desktop_vaults"] as JsonArray).map { it.obj()["id"]!!.jsonPrimitive.content })
        val applied = CopySettings.apply(edited, only, ownNpub = null)
        assertTrue("the peer's change was not taken in", applied.zapsOnlyMode)
        assertFalse("the edit here was reverted", applied.showNewPostsPill)
        // Positive control: the whole file reverts the edit.
        assertTrue(CopySettings.apply(edited, theirs, ownNpub = null).showNewPostsPill)
        // With no edit here, the whole file is applied as before.
        val plain = CopySettingsSync.step(base, CopySettings.file(theirs, 200), base.toString(), 100, now, setupDone = true)
        assertNull((plain as Step.Apply).only)
    }

    @Test
    fun `an empty Vault list is left out`() {
        assertFalse("desktop_vaults" in CopySettings.keys(HavenConfig(), ownNpub = null, nowS = now))
        val c = HavenConfig(desktopVaults = listOf(DesktopVault(id = "https:a.example", httpsURL = "https://a.example")))
        assertTrue("desktop_vaults" in CopySettings.keys(c, ownNpub = null, nowS = now))
    }
}
