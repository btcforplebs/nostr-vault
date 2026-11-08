package com.nostrvault.service

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
                "fun publishServerList(dropMesh: Collection<String> = emptyList(), onRefused: (String) -> Unit = {}) { publishServerListImpl(dropMesh, onRefused) }",
                "internal fun NostrService.publishServerListImpl(dropMesh: Collection<String> = emptyList(), onRefused: (String) -> Unit = {}) {",
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

    /** Logen 2026-11-08: linking or removing a vault does not touch the 10063, now or at the next Save. */
    @Test
    fun `only Media Servers changes which vaults are listed`() {
        val writes = Regex("""serverList(Add|Drop)Mesh\s*=""")
        // Positive control: the pattern catches the write My Devices used to make.
        assertTrue(writes.containsMatchIn("it.copy(serverListDropMesh = serverListDropsAfter(before, it))"))
        assertEquals(
            listOf("MediaServerVaults.kt", "NostrServiceListPublishing.kt"),
            sources.filter { f -> f.readLines().any(writes::containsMatchIn) }.map { it.name }.sorted(),
        )
    }

    @Test
    fun `Save passes the owner's adds and drops and clears them only after posting`() {
        val src = File("src/main/java/com/nostrvault/service/nostr/NostrServiceListPublishing.kt").readText()
        val impl = src.substringAfter("fun NostrService.publishServerListImpl").substringBefore("\n    }\n")
        assertTrue("reads the adds", impl.contains("val add = config.serverListAddMesh"))
        assertTrue("reads the drops", impl.contains("val drop = (dropMesh + config.serverListDropMesh).distinct()"))
        assertTrue("merges with them", impl.contains("mergeServerList(servers, servers, add, drop)"))
        assertTrue("clears what it used", impl.contains("serverListAddMesh = it.serverListAddMesh - add.toSet(), serverListDropMesh = it.serverListDropMesh - drop.toSet()"))
        assertTrue("on posting", impl.contains("onPosted = cleared"))
        assertTrue("no vault is listed on its own", !impl.contains("homeVaultNpub") && !impl.contains("linkedMacs"))
        val merged = src.substringAfter("fun NostrService.publishMergedList(").substringBefore("\n    }\n")
        assertTrue("onPosted after the post", merged.indexOf("onPosted()") > merged.indexOf("postEvent(event)"))
    }

    @Test
    fun `Media servers warns when no server is https`() {
        assertTrue(ServerListAdoption.allPlainHttp(listOf("http://a.example")))
        assertTrue(!ServerListAdoption.allPlainHttp(listOf("http://a.example", "https://b.example")))
        assertTrue(!ServerListAdoption.allPlainHttp(emptyList()))
    }
}
