package com.nostrvault.fips

import com.nostrvault.fips.CopySettingsSync.Step
import com.nostrvault.fips.MeshCopyFixtures.obj
import com.nostrvault.relay.DesktopVault
import com.nostrvault.relay.HavenConfig
import com.nostrvault.relay.desktopVaultMeshNpubs
import kotlinx.serialization.json.JsonArray
import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.JsonPrimitive
import kotlinx.serialization.json.jsonArray
import kotlinx.serialization.json.jsonPrimitive
import kotlinx.serialization.json.long
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

/** The Desktop Vault list in the settings copy (Desktop Vaults P10, plan §2.6, contract §5). iOS CopyVaultsTests. */
class CopyVaultsTest {
    private val now = 1767000300L

    @Test
    fun `merge matches the fixture`() {
        val f = MeshCopyFixtures.json("settings-vault-merge-cases.json")
        assertEquals(CopyVaults.TOMB_DAYS, f["tombstone_days"]!!.jsonPrimitive.long)
        val at = f["now"]!!.jsonPrimitive.long
        val cases = f["cases"]!!.jsonArray.map { it.obj() }
        assertTrue(cases.size >= 10)
        for (c in cases) {
            val got = CopyVaults.merge(list(c["mine"]), list(c["theirs"]), at)
            assertEquals(c["name"]!!.jsonPrimitive.content, list(c["expect"]), got)
        }
    }

    private fun list(e: kotlinx.serialization.json.JsonElement?) = (e as JsonArray).map { it.obj() }

    /** Two real npubs from the fixtures (a Mac and a box). */
    private fun npubs(): Pair<String, String> {
        val clean = MeshCopyFixtures.json("settings-refuse-cases.json")["cases"]!!.jsonArray.map { it.obj() }
            .first { it["name"]!!.jsonPrimitive.content == "vault list, clean" }
        val l = clean["settings"]!!.obj()["keys"]!!.obj()["desktop_vaults"]!!.jsonArray.map { it.obj() }
        return l[0]["meshNpub"]!!.jsonPrimitive.content to l[1]["meshNpub"]!!.jsonPrimitive.content
    }

    private fun entry(id: String, mesh: String? = null, https: String? = null, order: Int = 0, at: Long = 1767000000, name: String = "") =
        JsonObject(buildMap {
            put("id", JsonPrimitive(id)); put("name", JsonPrimitive(name)); put("kind", JsonPrimitive("mac"))
            put("order", JsonPrimitive(order)); put("updatedAt", JsonPrimitive(at))
            mesh?.let { put("meshNpub", JsonPrimitive(it)) }
            https?.let { put("httpsURL", JsonPrimitive(it)) }
        })

    private fun tomb(id: String, at: Long) = JsonObject(mapOf("id" to JsonPrimitive(id), "deletedAt" to JsonPrimitive(at)))

    private fun out(c: HavenConfig, previous: List<JsonObject>, own: String? = null) =
        (CopySettings.keys(c, JsonArray(previous), own, now)["desktop_vaults"] as JsonArray).map { it.obj() }.associateBy { it["id"]!!.jsonPrimitive.content }

    @Test
    fun `apply adds and removes per Vault, and exporting after it dates nothing new`() {
        val c = HavenConfig(desktopVaults = listOf(
            DesktopVault(id = "https:here.example", name = "Here", httpsURL = "https://here.example", order = 0),
            DesktopVault(id = "https:gone.example", name = "Gone", httpsURL = "https://gone.example", order = 1),
        ))
        val file = listOf(entry("https:here.example", https = "https://here.example", order = 0, name = "Here"),
            entry("https:there.example", https = "https://there.example", order = 1, name = "There"),
            tomb("https:gone.example", 1767000100))
        val applied = CopySettings.apply(c, JsonObject(mapOf("desktop_vaults" to JsonArray(file))), ownNpub = null)
        assertEquals(listOf("https:here.example", "https:there.example"), applied.desktopVaults.map { it.id })
        val exported = CopySettings.keys(applied, JsonArray(file), null, now)["desktop_vaults"] as JsonArray
        assertEquals(CopyVaults.merge(file, emptyList(), now), exported.map { it.obj() })
    }

    @Test
    fun `export dates a delete and an edit now and keeps an unchanged stamp`() {
        val previous = listOf(entry("https:a.example", https = "https://a.example", order = 0, name = "A"),
            entry("https:b.example", https = "https://b.example", order = 1, name = "B"),
            entry("https:c.example", https = "https://c.example", order = 2, name = "C"))
        val c = HavenConfig(desktopVaults = listOf(
            DesktopVault(id = "https:a.example", name = "A", httpsURL = "https://a.example", order = 0),
            DesktopVault(id = "https:b.example", name = "B renamed", httpsURL = "https://b.example", order = 1),
        ))
        val byId = out(c, previous)
        assertEquals(1767000000L, byId["https:a.example"]!!["updatedAt"]!!.jsonPrimitive.long)
        assertEquals(now, byId["https:b.example"]!!["updatedAt"]!!.jsonPrimitive.long)
        assertEquals(now, byId["https:c.example"]!!["deletedAt"]!!.jsonPrimitive.long)
        assertNull(CopySettings.refusal(CopySettings.file(CopySettings.keys(c, JsonArray(previous), null, now), now), now))
    }

    /**
     * A copied Vault grants nothing (§2.6): applying a Vault list naming a mesh npub this device isn't paired with
     * leaves My Devices as it was, gives that npub no mesh lane, and the next export neither strips nor deletes the
     * address it couldn't hold.
     */
    @Test
    fun `a copied Vault never grants pairing`() {
        val (mac, box) = npubs()
        val c = HavenConfig(fipsMesh = FipsMeshSettings(devices = listOf(FipsDevice(npub = mac, role = DeviceRole.MAC, name = "Studio Mac"))))
        val file = listOf(entry("mesh:$mac", mesh = mac, order = 0, name = "Studio Mac"),
            entry("mesh:$box", mesh = box, order = 1, name = "Box"),
            entry("https:web.example", mesh = box, https = "https://web.example", order = 2, name = "Web"))
        val applied = CopySettings.apply(c, JsonObject(mapOf("desktop_vaults" to JsonArray(file))), ownNpub = null)
        assertEquals("a copied Vault changed My Devices", c.fipsMesh, applied.fipsMesh)
        val lanes = applied.desktopVaultMeshNpubs(null)
        assertTrue("positive control: the paired Mac's Vault is dialed", mac in lanes)
        assertFalse("a copied Vault's unpaired mesh npub got a mesh lane", box in lanes)
        val byId = out(applied, file)
        assertEquals(box, byId["mesh:$box"]!!["meshNpub"]!!.jsonPrimitive.content)
        assertNull(byId["mesh:$box"]!!["deletedAt"])
        assertEquals(box, byId["https:web.example"]!!["meshNpub"]!!.jsonPrimitive.content)
        assertEquals(1767000000L, byId["https:web.example"]!!["updatedAt"]!!.jsonPrimitive.long)
    }

    @Test
    fun `this device's own entry is left out on apply and never deleted`() {
        val (mac, _) = npubs()
        val file = listOf(entry("mesh:$mac", mesh = mac, order = 0, name = "This Mac"), entry("https:b.example", https = "https://b.example", order = 1))
        val applied = CopySettings.apply(HavenConfig(), JsonObject(mapOf("desktop_vaults" to JsonArray(file))), ownNpub = mac)
        assertEquals(listOf("https:b.example"), applied.desktopVaults.map { it.id })
        val byId = out(applied, file, own = mac)
        assertEquals(listOf("mesh:$mac", "https:b.example"), byId.keys.toList())
        assertNull(byId["mesh:$mac"]!!["deletedAt"])
    }

    @Test
    fun `order is the file's unless reordered here`() {
        val previous = listOf(entry("https:a.example", https = "https://a.example", order = 3), entry("https:b.example", https = "https://b.example", order = 7))
        var c = HavenConfig(desktopVaults = listOf(DesktopVault(id = "https:a.example", httpsURL = "https://a.example", order = 0),
            DesktopVault(id = "https:b.example", httpsURL = "https://b.example", order = 1)))
        assertEquals(listOf(1767000000L, 1767000000L), out(c, previous).values.map { it["updatedAt"]!!.jsonPrimitive.long })
        c = c.copy(desktopVaults = listOf(DesktopVault(id = "https:b.example", httpsURL = "https://b.example", order = 0),
            DesktopVault(id = "https:a.example", httpsURL = "https://a.example", order = 1)))
        val o = out(c, previous)
        assertEquals(listOf("https:b.example", "https:a.example"), o.keys.toList())
        assertEquals(listOf(now, now), o.values.map { it["updatedAt"]!!.jsonPrimitive.long })
    }

    /** A merge can change the Vault list and keep the newer side's date: that file is still applied, not written over. */
    @Test
    fun `an engine merge with the same date but new Vaults is applied`() {
        val mine = CopySettings.keys(HavenConfig(), JsonArray(emptyList()), null, now)
        val merged = JsonObject(mine + ("desktop_vaults" to JsonArray(listOf(entry("https:new.example", https = "https://new.example")))))
        val s = CopySettingsSync.step(mine, CopySettings.file(merged, 100), mine.toString(), 100, now, setupDone = true)
        assertTrue("written over: the new Vault would read as deleted here", s is Step.Apply)
    }
}
