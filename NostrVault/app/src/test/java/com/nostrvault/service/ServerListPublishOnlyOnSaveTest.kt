package com.nostrvault.service

import com.nostrvault.fips.DeviceRole
import com.nostrvault.fips.FipsDevice
import com.nostrvault.fips.FipsMeshSettings
import com.nostrvault.fips.HomeVaultRules
import com.nostrvault.relay.HavenConfig
import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Test
import java.io.File

/**
 * Kind 10063 goes out only from Save in Media servers (Logen 2026-10-31).
 * Reading a list and My Devices changes used to republish it on their own.
 */
class ServerListPublishOnlyOnSaveTest {

    private val sources = File("src/main/java").walkTopDown().filter { it.isFile && it.extension == "kt" }.toList()

    /** Files outside the publish code that name [pattern] other than where it is declared. */
    private fun filesUsing(pattern: Regex, declaredIn: Set<String>) = sources
        .filter { it.name !in declaredIn && it.readLines().any(pattern::containsMatchIn) }
        .map { it.name }
        .sorted()

    @Test
    fun `publishServerList is used only by Media servers Save`() {
        // No bracket: a call, a `::publishServerList` reference and a call to the Impl all match (Tron #1451).
        assertEquals(
            listOf("BlossomSettingsScreen.kt"),
            filesUsing(Regex("publishServerList"), setOf("NostrService.kt", "NostrServiceListPublishing.kt")),
        )
        // In the two declaring files, only the declarations and the one wrapper call name it.
        val declared = listOf("NostrService.kt", "NostrServiceListPublishing.kt").flatMap { name ->
            sources.first { it.name == name }.readLines().filter { "publishServerList" in it }.map(String::trim)
        }
        assertEquals(
            listOf(
                "fun publishServerList(dropMesh: Collection<String> = emptyList()) { publishServerListImpl(dropMesh) }",
                "internal fun NostrService.publishServerListImpl(dropMesh: Collection<String> = emptyList()) {",
            ),
            declared,
        )
    }

    @Test
    fun `nothing else publishes a 10063`() {
        val publishing = File("src/main/java/com/nostrvault/service/nostr/NostrServiceListPublishing.kt").readText()
        assertEquals("one publishOwnerEntryList(10063", 1, Regex("publishOwnerEntryList\\(\\s*10063").findAll(publishing).count())
        val direct = Regex("(signAndPost|signEvent\\w*|publish\\w*)\\(\\s*(kind\\s*=\\s*)?10063\\b")
        // Positive control: the pattern catches the direct publishes it guards against.
        listOf("signAndPost(kind = 10063, content = \"\")", "signEventAsync(10063", "publishOwnerEntryList(10063, \"server\"")
            .forEach { assertTrue(it, direct.containsMatchIn(it)) }
        assertEquals(emptyList<String>(), filesUsing(direct, setOf("NostrServiceListPublishing.kt")))
    }

    private val mac = "npub14h99va9qsxge8yac0aqjqg000vhux4ugrvkqayv8ehsunhft4mtstp4dfk"
    private val kiosk = "npub1" + "q".repeat(58)

    private fun linked(home: String?, macs: List<String>) = HavenConfig(
        homeVaultNpub = home,
        fipsPeers = macs + listOfNotNull(home),
        fipsMesh = FipsMeshSettings(devices = macs.map { FipsDevice(it, role = DeviceRole.MAC) }),
    )

    @Test
    fun `an unlinked Mac or home vault waits for Save, then Save drops it`() {
        val before = linked(kiosk, listOf(mac))
        assertEquals("the Mac is listed", listOf(mac), linkedMacs(before))
        val after = linked(null, emptyList())
        val pending = serverListDropsAfter(before, after)
        assertEquals(listOf(kiosk, mac), pending)
        // Relinked before Save: no longer dropped.
        assertEquals(listOf(kiosk), serverListDropsAfter(after, linked(null, listOf(mac)), pending))
        // What Save merges with them: both fipsmesh entries leave the newest list.
        val newest = listOf("https://a.example", "fipsmesh://$kiosk/", "fipsmesh://$mac/")
        assertEquals(
            listOf("https://a.example"),
            HomeVaultRules.mergeServerList(newest, newest, after.homeVaultNpub, pending, linkedMacs(after), after.fipsPeers),
        )
    }

    @Test
    fun `Save passes the pending drops and clears them only after posting`() {
        val src = File("src/main/java/com/nostrvault/service/nostr/NostrServiceListPublishing.kt").readText()
        val impl = src.substringAfter("fun NostrService.publishServerListImpl").substringBefore("\n    }\n")
        assertTrue("reads them", impl.contains("val drop = (dropMesh + config.serverListDropMesh).distinct()"))
        assertTrue("merges with them", impl.contains("servers, servers, home, drop, macs, myDevices = config.fipsPeers"))
        assertTrue("clears what it dropped", impl.contains("serverListDropMesh = it.serverListDropMesh - drop.toSet()"))
        assertTrue("on posting", impl.contains("onPosted = cleared"))
        val merged = src.substringAfter("private fun NostrService.publishMergedList").substringBefore("\n    }\n")
        assertTrue("onPosted after the post", merged.indexOf("onPosted()") > merged.indexOf("postEvent(event)"))
        val vm = File("src/main/java/com/nostrvault/ui/screens/settings/fipsmesh/FipsMeshViewModel.kt").readText()
        assertTrue("My Devices records them", vm.contains("serverListDropMesh = com.nostrvault.service.serverListDropsAfter(before, it)"))
    }

    @Test
    fun `Media servers warns when no server is https`() {
        assertTrue(ServerListAdoption.allPlainHttp(listOf("http://a.example")))
        assertTrue(!ServerListAdoption.allPlainHttp(listOf("http://a.example", "https://b.example")))
        assertTrue(!ServerListAdoption.allPlainHttp(emptyList()))
    }
}
