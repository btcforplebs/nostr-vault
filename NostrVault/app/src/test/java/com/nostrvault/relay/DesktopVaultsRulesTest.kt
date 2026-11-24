package com.nostrvault.relay

import com.nostrvault.fips.FipsDevice
import kotlinx.serialization.builtins.ListSerializer
import kotlinx.serialization.builtins.MapSerializer
import kotlinx.serialization.builtins.serializer
import kotlinx.serialization.json.Json
import kotlinx.serialization.json.JsonElement
import kotlinx.serialization.json.JsonNull
import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.boolean
import kotlinx.serialization.json.int
import kotlinx.serialization.json.jsonArray
import kotlinx.serialization.json.jsonObject
import kotlinx.serialization.json.jsonPrimitive
import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Test
import java.io.File

/**
 * Desktop Vaults (PLANS/NV_DESKTOP_VAULTS_PLAN.md §2.5, §3) on the shared fixtures in docs/fixtures/desktop-vaults,
 * the same files iOS DesktopVaultsTests reads. iOS twin of each test named in its comment.
 */
class DesktopVaultsRulesTest {
    private val dir = File("../../docs/fixtures/desktop-vaults")
    private val json = Json { ignoreUnknownKeys = true }

    private fun fixture(name: String): JsonObject = Json.parseToJsonElement(File(dir, "$name.json").readText()).jsonObject
    private fun tags(e: JsonElement?): List<List<String>> = e!!.jsonArray.map { t -> t.jsonArray.map { it.jsonPrimitive.content } }
    private fun vaults(e: JsonElement?): List<DesktopVault> = json.decodeFromJsonElement(ListSerializer(DesktopVault.serializer()), e!!)
    private fun devices(e: JsonElement?): List<FipsDevice> = json.decodeFromJsonElement(ListSerializer(FipsDevice.serializer()), e!!)
    private fun list(e: JsonElement?): DesktopVaultList = DesktopVaultList.ofKind(e!!.jsonPrimitive.int)!!
    private fun str(e: JsonElement?): String? = e?.takeUnless { it is JsonNull }?.jsonPrimitive?.content

    // ── lists.json (§2.5 rules 1-6); iOS testListRulesFixture ──

    @Test
    fun listRulesFixture() {
        val doc = fixture("lists")
        val named = json.decodeFromJsonElement(MapSerializer(String.serializer(), DesktopVault.serializer()), doc["vaults"]!!)
        val all = named.values.toList()
        fun keyOf(v: DesktopVault?) = named.entries.firstOrNull { it.value.id == v?.id }?.key
        val cases = doc["cases"]!!.jsonArray.map { it.jsonObject }
        assertTrue(cases.size > 40)
        var ran = 0
        for (c in cases) {
            val name = str(c["name"])!!
            val expect = c["expect"]!!.jsonObject
            val vault = str(c["vault"])?.let { named[it] }
            val path = str(c["path"])?.let { DesktopVaultPath.valueOf(it.uppercase()) }
            when (str(c["op"])) {
                "owner" -> assertEquals(name, str(expect["owner"]),
                    keyOf(DesktopVaultsLists.owner(tags(JsonArrayOf(c["tag"]!!))[0], list(c["list"]), all)))
                "on", "off" -> {
                    val t = tags(c["tags"])
                    val change = if (str(c["op"]) == "on") DesktopVaultsLists.turningOn(vault!!, path!!, list(c["list"]), t, all)
                    else DesktopVaultsLists.turningOff(vault!!, path!!, list(c["list"]), t)
                    val want = expect["refused"]?.let { DesktopVaultListChange.Refused(list(it)) }
                        ?: DesktopVaultListChange.Tags(tags(expect["tags"]))
                    assertEquals(name, want, change)
                    if (str(c["op"]) == "on" && change is DesktopVaultListChange.Tags && change.tags != t) {
                        assertTrue(name, DesktopVaultsLists.isListed(vault, path, list(c["list"]), change.tags))
                    }
                }
                "remove" -> {
                    val lists = c["lists"]!!.jsonObject.entries.associate { (k, v) -> DesktopVaultList.ofKind(k.toInt())!! to tags(v) }
                    val want = expect["refused"]?.let { DesktopVaultsLists.Removal.Refused(list(it)) }
                        ?: DesktopVaultsLists.Removal.Changed(
                            expect["changed"]!!.jsonObject.entries.associate { (k, v) -> DesktopVaultList.ofKind(k.toInt())!! to tags(v) },
                        )
                    assertEquals(name, want, DesktopVaultsLists.removingVault(vault!!, lists))
                }
                "reorder" -> assertEquals(name, tags(expect["tags"]), DesktopVaultsLists.reordered(tags(c["tags"]), list(c["list"]), all))
                "overGuidance" -> assertEquals(name, expect["over"]!!.jsonPrimitive.boolean,
                    DesktopVaultsLists.overGuidance(tags(c["tags"]), list(c["list"])))
                "hostTaken" -> {
                    val except = str(c["except"])?.let { named[it]?.id }
                    assertEquals(name, str(expect["owner"]), keyOf(DesktopVaultsLists.hostTaken(str(c["url"])!!, all, except)))
                }
                else -> throw AssertionError("unknown op in $name")
            }
            ran++
        }
        assertEquals(cases.size, ran)
    }

    private fun JsonArrayOf(e: JsonElement) = kotlinx.serialization.json.JsonArray(listOf(e))

    // ── migration.json (§3); iOS testMigrationFixture, testDerivedAddressesFixture, testStatusFileNamesMatchTheEngine ──

    @Test
    fun migrationFixture() {
        val cases = fixture("migration")["migration"]!!.jsonArray.map { it.jsonObject }
        assertTrue(cases.size > 10)
        for (c in cases) {
            val out = DesktopVaultsRules.takingInSlot(vaults(c["vaults"]), str(c["slot"])!!, str(c["taken"]), devices(c["devices"]))
            assertEquals(str(c["name"]), vaults(c["expect"]), out)
        }
    }

    @Test
    fun derivedAddressesFixture() {
        for (c in fixture("migration")["derived"]!!.jsonArray.map { it.jsonObject }) {
            val name = str(c["name"])
            val v = vaults(c["vaults"])
            val expect = c["expect"]!!.jsonObject
            assertEquals(name, expect["wss"]!!.jsonArray.map { it.jsonPrimitive.content }, DesktopVaultsRules.wssURLs(v))
            assertEquals(name, expect["https"]!!.jsonArray.map { it.jsonPrimitive.content }, DesktopVaultsRules.httpsURLs(v))
            assertEquals(name, str(expect["env"]), DesktopVaultsRules.envList(v, str(c["slot"])!!))
        }
    }

    @Test
    fun statusFileNamesMatchTheEngine() {
        val rows = fixture("migration")["statusFiles"]!!.jsonArray.map { it.jsonObject }
        assertTrue(rows.any { str(it["file"])!!.length == "mac_sync_status-".length + 64 + ".json".length })
        for (row in rows) assertEquals(str(row["base"]), str(row["file"]), DesktopVaultsRules.statusFileName(str(row["base"])!!))
    }

    // ── The config the app runs on ──

    /** A one-slot user gets exactly the relay lists they had. iOS testSlotUserKeepsTheirRelayLists. */
    @Test
    fun slotUserKeepsTheirRelayLists() {
        for (slot in listOf("wss://mac.example.com/", "https://Mac.Example.com", "ws://192.168.1.5:3355", "mac.example.com/haven")) {
            val before = HavenConfig(
                feedRelays = listOf("wss://relay.damus.io"), blastrRelays = listOf("wss://nos.lol"),
                blossomMirrors = listOf("https://blossom.primal.net"), macRelayURL = slot,
            )
            val wss = before.macRelayWssURL
            val https = before.macRelayHttpsURL
            val config = before.takingInDesktopVaultSlot()
            assertEquals(slot, 1, config.desktopVaults.size)
            assertEquals(slot, config.desktopVaultsSlot)
            assertEquals("the slot is never rewritten", slot, config.macRelayURL)
            assertEquals(slot, listOf(wss, "wss://relay.damus.io"), config.activeFeedRelays)
            assertEquals(slot, listOf(wss, "wss://nos.lol"), config.activeBlastrRelays)
            assertEquals(slot, listOf(https, "https://blossom.primal.net"), config.activeBlossomMirrors)
            assertEquals(slot, "", DesktopVaultsRules.envList(config.desktopVaultsInEffect, config.macRelayURL))
        }
    }

    /** iOS testEveryHTTPSVaultFeedsTheDerivedLists. */
    @Test
    fun everyHTTPSVaultFeedsTheDerivedLists() {
        val config = HavenConfig(
            feedRelays = listOf("wss://relay.damus.io", "wss://b.example.com"),
            blossomMirrors = listOf("https://blossom.primal.net"),
            desktopVaultsSlot = "",
            desktopVaults = listOf(
                DesktopVault(id = "b", httpsURL = "https://b.example.com", order = 1),
                DesktopVault(id = "c", meshNpub = "npub1" + "c".repeat(58), order = 2),
                DesktopVault(id = "a", httpsURL = "https://a.example.com", order = 0),
            ),
        )
        // b is already a feed relay and keeps its place, as the slot did.
        assertEquals(listOf("wss://a.example.com", "wss://relay.damus.io", "wss://b.example.com"), config.activeFeedRelays)
        assertEquals(listOf("https://a.example.com", "https://b.example.com", "https://blossom.primal.net"), config.activeBlossomMirrors)
        assertEquals(listOf("https://blossom.primal.net"), config.blossomDeleteTargets(emptyList(), null, includeHomeVault = false))
        assertEquals("wss://a.example.com,wss://b.example.com", DesktopVaultsRules.envList(config.desktopVaultsInEffect, config.macRelayURL))
    }

    /** The old Haven relay field still edits the slot until P7. iOS testOldTabEditCountsBeforeSave. */
    @Test
    fun oldFieldEditCountsAtOnce() {
        val taken = HavenConfig(feedRelays = emptyList(), macRelayURL = "https://old.example.com").takingInDesktopVaultSlot()
        assertEquals(listOf("wss://new.example.com"), taken.copy(macRelayURL = "https://new.example.com").activeFeedRelays)
        assertEquals(emptyList<String>(), taken.copy(macRelayURL = "").activeFeedRelays)
    }

    /** Tron M1 on #2499. iOS testOldTabPathEditOnSameHost. */
    @Test
    fun oldFieldPathEditOnSameHost() {
        val taken = HavenConfig(feedRelays = emptyList(), blossomMirrors = emptyList(), macRelayURL = "https://mac.example.com/haven")
            .takingInDesktopVaultSlot()
        val edited = taken.copy(macRelayURL = "https://mac.example.com/relay")
        assertEquals(listOf(edited.macRelayWssURL), edited.activeFeedRelays)
        assertEquals(listOf("wss://mac.example.com/relay"), edited.activeFeedRelays)
        assertEquals(listOf("https://mac.example.com/relay"), edited.activeBlossomMirrors)
        val saved = edited.takingInDesktopVaultSlot()
        assertEquals(listOf("https://mac.example.com/relay"), saved.desktopVaults.map { it.httpsURL })
        assertEquals(listOf("wss://mac.example.com/relay"), saved.activeFeedRelays)
    }

    /** Tron S2 on #2499. iOS testEntryKeepsThePath. */
    @Test
    fun entryKeepsThePath() {
        val vault = DesktopVault(id = "h", httpsURL = "https://mac.example.com/haven")
        assertEquals(listOf("r", "wss://mac.example.com/haven"), DesktopVaultsLists.entry(vault, DesktopVaultPath.WEB, DesktopVaultList.RELAYS))
        assertEquals(listOf("relay", "wss://mac.example.com/haven/inbox"), DesktopVaultsLists.entry(vault, DesktopVaultPath.WEB, DesktopVaultList.INBOX))
        assertEquals(listOf("server", "https://mac.example.com/haven"), DesktopVaultsLists.entry(vault, DesktopVaultPath.WEB, DesktopVaultList.MEDIA))
        assertTrue(DesktopVaultsLists.isListed(vault, DesktopVaultPath.WEB, DesktopVaultList.RELAYS, listOf(listOf("r", "wss://mac.example.com/haven"))))
    }

    /** Tron S1 on #2499: a Vault list that is not a list reads as empty and the slot is migrated again. iOS testUnreadableListIsMigratedAgain. */
    @Test
    fun unreadableListIsMigratedAgain() {
        val text = """{"macRelayURL":"https://mac.example.com","desktopVaults":{"oops":1},"desktopVaultsSlot":"https://mac.example.com"}"""
        assertTrue(DesktopVaultsRules.unreadableList(text))
        val decoded = json.decodeFromString(HavenConfig.serializer(), text)
        assertEquals(emptyList<DesktopVault>(), decoded.desktopVaults)
        val reset = decoded.copy(desktopVaultsSlot = null).takingInDesktopVaultSlot()
        assertEquals(listOf("https://mac.example.com"), reset.desktopVaults.map { it.httpsURL })
        // A list, an empty list or no key at all is not "unreadable".
        assertEquals(false, DesktopVaultsRules.unreadableList("""{"desktopVaults":[]}"""))
        assertEquals(false, DesktopVaultsRules.unreadableList("""{"macRelayURL":""}"""))
    }

    /**
     * Tron M1 on #2500: a stored list that loads empty after the slot was taken in never loses the slot's Vault, so
     * the owner's Mac stays in the feed and Blossom lists and out of "Delete from mirrors".
     */
    @Test
    fun lostListKeepsTheSlotVault() {
        val mac = "https://mac.example.com"
        val lost = listOf(
            """{"macRelayURL":"$mac","feedRelays":[],"blossomMirrors":[],"desktopVaults":null,"desktopVaultsSlot":"$mac"}""",
            """{"macRelayURL":"$mac","feedRelays":[],"blossomMirrors":[],"desktopVaults":[{"id":7,"httpsURL":"$mac"}],"desktopVaultsSlot":"$mac"}""",
        )
        for (text in lost) {
            assertTrue(text, DesktopVaultsRules.unreadableList(text))
            // Even without the reset ConfigStore does on an unreadable list, the slot's Vault comes back.
            val decoded = json.decodeFromString(HavenConfig.serializer(), text)
            assertEquals(emptyList<DesktopVault>(), decoded.desktopVaults)
            assertEquals(mac, decoded.desktopVaultsSlot)
            assertEquals(listOf("wss://mac.example.com"), decoded.activeFeedRelays)
            assertEquals(listOf(mac), decoded.activeBlossomMirrors)
            assertEquals(emptyList<String>(), decoded.blossomDeleteTargets(listOf(mac), null, includeHomeVault = false))
            val saved = json.decodeFromString(HavenConfig.serializer(), json.encodeToString(HavenConfig.serializer(), decoded.takingInDesktopVaultSlot()))
            assertEquals(listOf(mac), saved.desktopVaults.map { it.httpsURL })
        }
        // A mesh slot comes back the same way; this device's own npub never does.
        val npub = "npub1" + "a".repeat(58)
        assertEquals(listOf(npub), DesktopVaultsRules.takingInSlot(emptyList(), npub, npub, emptyList()).map { it.meshNpub })
        assertEquals(emptyList<DesktopVault>(), DesktopVaultsRules.takingInSlot(emptyList(), npub, npub, emptyList(), ownNpub = npub))
        // Belt and braces until P7: the slot is never a delete target even when no Vault holds it.
        val bare = HavenConfig(macRelayURL = mac, blossomMirrors = emptyList(), desktopVaultsSlot = mac)
        assertEquals(emptyList<String>(), bare.blossomDeleteTargets(listOf(mac), null, includeHomeVault = false))
        assertEquals(listOf(mac), bare.blossomDeleteTargets(emptyList(), null, includeHomeVault = true))
        // A list with one readable Vault is not "unreadable".
        assertEquals(false, DesktopVaultsRules.unreadableList("""{"desktopVaults":[{"id":7},{"id":"a"}]}"""))
    }

    /** iOS testConfigRoundTripAndUnknownVaultSkipped. */
    @Test
    fun configRoundTripAndUnknownVaultSkipped() {
        val config = HavenConfig(
            desktopVaultsSlot = "",
            desktopVaults = listOf(DesktopVault(id = "a", name = "Mac", kind = DesktopVaultKind.BOX, httpsURL = "https://a.example.com")),
        )
        val text = json.encodeToString(HavenConfig.serializer(), config)
        assertTrue(text, text.contains("\"kind\":\"box\""))
        val withOdd = text.replace(
            "\"desktopVaults\":[",
            "\"desktopVaults\":[{\"name\":\"no id\"},{\"id\":\"z\",\"kind\":\"toaster\",\"order\":3,\"httpsURL\":\"https://z.example.com\"},",
        )
        val back = json.decodeFromString(HavenConfig.serializer(), withOdd)
        assertEquals(listOf("z", "a"), back.desktopVaults.map { it.id })
        assertEquals(DesktopVaultKind.MAC, back.desktopVaults.first().kind)
        assertEquals("", back.desktopVaultsSlot)
        val old = json.decodeFromString(HavenConfig.serializer(), """{"ownerNpub":""}""")
        assertEquals(emptyList<DesktopVault>(), old.desktopVaults)
        assertEquals(null, old.desktopVaultsSlot)
    }
}
