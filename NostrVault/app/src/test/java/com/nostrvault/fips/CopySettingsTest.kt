package com.nostrvault.fips

import com.nostrvault.fips.MeshCopyFixtures.obj
import com.nostrvault.relay.AccountBunkerConfig
import com.nostrvault.relay.HavenConfig
import kotlinx.serialization.json.Json
import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.boolean
import kotlinx.serialization.json.jsonArray
import kotlinx.serialization.json.jsonPrimitive
import kotlinx.serialization.json.long
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

/** Contract §5: the allowlist, the refuse rules (fixtures), and what this app's export may never carry. */
class CopySettingsTest {

    @Test
    fun `the allowlist is settings-allowlist json, key for key and type for type`() {
        val keys = MeshCopyFixtures.json("settings-allowlist.json")["keys"]!!.obj()
        val types = mapOf(
            "bool" to CopySettings.Type.BOOL, "int" to CopySettings.Type.INT, "string[]" to CopySettings.Type.STRINGS,
            "object<string>" to CopySettings.Type.OBJECT_STRING, "object<bool>" to CopySettings.Type.OBJECT_BOOL,
        )
        assertEquals(keys.mapValues { types.getValue(it.value.obj()["type"]!!.jsonPrimitive.content) }, CopySettings.ALLOWLIST)
        val wot = keys["wot_depth"]!!.obj()
        assertEquals(wot["min"]!!.jsonPrimitive.long.toInt()..wot["max"]!!.jsonPrimitive.long.toInt(), CopySettings.WOT_DEPTH_RANGE)
    }

    @Test
    fun `every refuse case`() {
        val f = MeshCopyFixtures.json("settings-refuse-cases.json")
        val now = f["now"]!!.jsonPrimitive.long
        val cases = f["cases"]!!.jsonArray.map { it.obj() }
        assertTrue(cases.size >= 23)
        for (c in cases) {
            val name = c["name"]!!.jsonPrimitive.content
            val expect = c["expect"]!!.obj()
            val want = if (expect["ok"]!!.jsonPrimitive.boolean) null else expect["reason"]!!.jsonPrimitive.content
            assertEquals(name, want, CopySettings.refusal(c["settings"]!!.toString(), now))
        }
    }

    /**
     * The build-failing test (plan §4): a config holding every kind of secret exports only allowlisted keys and
     * none of the secrets. The positive control: the same scan finds them in the raw config.
     */
    @Test
    fun `the export never carries a secret the config holds`() {
        val nsec = "nsec1" + "x".repeat(58)
        val ncryptsec = "ncryptsec1" + "y".repeat(40)
        val nwc = "nostr+walletconnect://" + "1".repeat(64) + "?relay=wss://r.example&secret=" + "2".repeat(64)
        val bunker = "bunker://" + "3".repeat(64) + "?relay=wss://r.example"
        val rawKey = "4".repeat(64)
        val c = full().copy(
            ownerHexKey = rawKey,
            ownerNcryptsec = ncryptsec,
            nwcURI = nwc,
            s3SecretKey = nsec,
            accountBunkerConfigs = mapOf("npub1a" to AccountBunkerConfig(bunkerURI = bunker, secret = nsec, clientSecretKey = rawKey)),
            homeVaultNpub = "npub1homevault",
        )
        val secrets = listOf(nsec, ncryptsec, nwc, bunker, rawKey)
        // Positive control: the scan sees each one in the config as a whole.
        val raw = c.toString()
        for (s in secrets) assertTrue("control: $s", s in raw)
        assertTrue(CopySettings.secretString(raw))

        val out = CopySettings.file(CopySettings.keys(c), 1767000000)
        for (s in secrets) assertFalse("leaked: $s", s in out)
        assertFalse("npub1homevault" in out)
        assertFalse(".fips" in out)
        val keys = (Json.parseToJsonElement(out) as JsonObject)["keys"]!!.obj()
        assertTrue(CopySettings.ALLOWLIST.keys.containsAll(keys.keys))
        assertNull(CopySettings.refusal(out, 1767000000))
    }

    @Test
    fun `exported and applied, a device holds the other's settings and keeps its own mesh servers`() {
        val a = full()
        val keys = CopySettings.keys(a)
        val b = HavenConfig(blossomMirrors = listOf("http://npub1mine.fips:3355"), chatRelayWotDepth = 3)
        val applied = CopySettings.apply(b, keys)
        assertEquals(a.feedLayoutModes, applied.feedLayoutModes)
        assertEquals(a.zapsOnlyMode, applied.zapsOnlyMode)
        assertEquals(a.autoLoadNewPosts, applied.autoLoadNewPosts)
        assertEquals(a.showNewPostsPill, applied.showNewPostsPill)
        assertEquals(2, applied.chatRelayWotDepth)
        assertEquals(a.blockedRelays, applied.blockedRelays)
        assertEquals(a.dmRelays, applied.dmRelays)
        assertEquals(listOf("https://blossom.example", "http://npub1mine.fips:3355"), applied.blossomMirrors)
        assertEquals(a.pushNotifyReactions, applied.pushNotifyReactions)
        assertEquals(a.pushNotifyMentions, applied.pushNotifyMentions)
        // Applied, the device exports the same keys again: no ping-pong on the next sync.
        assertEquals(keys, CopySettings.keys(applied))
    }

    @Test
    fun `a key not in the file keeps this device's value`() {
        val b = HavenConfig(zapsOnlyMode = true, dmRelays = listOf("wss://mine.example"))
        val applied = CopySettings.apply(b, Json.parseToJsonElement("""{"auto_load_new_posts":true}""") as JsonObject)
        assertTrue(applied.autoLoadNewPosts)
        assertTrue(applied.zapsOnlyMode)
        assertEquals(listOf("wss://mine.example"), applied.dmRelays)
    }

    @Test
    fun `the retired condensed layout reads and is sent as expanded`() {
        val file = Json.parseToJsonElement("""{"feed_layouts":{"Music":"condensed","Global":"threaded"}}""") as JsonObject
        val applied = CopySettings.apply(HavenConfig(), file)
        assertEquals(mapOf("Music" to "expanded", "Global" to "threaded"), applied.feedLayoutModes)
        val exported = CopySettings.keys(HavenConfig(feedLayoutModes = mapOf("Music" to "condensed")))["feed_layouts"]
        assertEquals(Json.parseToJsonElement("""{"Music":"expanded"}"""), exported)
        assertTrue(CopySettings.holdsRetiredLayout(file))
        assertFalse(CopySettings.holdsRetiredLayout(CopySettings.keys(applied)))
    }

    private fun full() = HavenConfig(
        feedLayoutModes = mapOf("following" to "cards", "global" to "compact"),
        zapsOnlyMode = true,
        autoLoadNewPosts = true,
        showNewPostsPill = false,
        chatRelayWotDepth = 2,
        blockedRelays = listOf("wss://bad.example"),
        dmRelays = listOf("wss://dm.example"),
        blossomMirrors = listOf("https://blossom.example", "http://npub1home.fips:3355"),
        pushNotifyMentions = false,
        pushNotifyReactions = true,
    )
}
