package com.nostrvault.service

import org.junit.After
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Rule
import org.junit.Test
import org.junit.rules.TemporaryFolder
import java.io.File

/** D3: "Delete from this device" only when another place proves a full copy, asked now; the list Auto-Mirror skips. iOS twin DeleteHereGateTests. */
class DeleteHereTest {
    @get:Rule val tmp = TemporaryFolder()
    private val sha = "ab".repeat(32)
    private val blob = "https://cdn.example/$sha"
    private fun ok206(total: String = "4096") = DeleteHereGate.Answer(206, "image/jpeg", "1", "bytes 0-0/$total", blob)

    @After fun reset() = DeviceRemovedStore.reset()

    @Test fun proofNeedsTheSameLength() {
        assertTrue(DeleteHereGate.proves(ok206(), sha, 4096))
        assertFalse("a different file under the hash", DeleteHereGate.proves(ok206("4095"), sha, 4096))
        assertFalse(DeleteHereGate.proves(ok206("*"), sha, 4096))
        assertTrue(DeleteHereGate.proves(DeleteHereGate.Answer(200, contentLength = "4096", finalUrl = blob), sha, 4096))
        assertFalse(DeleteHereGate.proves(DeleteHereGate.Answer(200, finalUrl = blob), sha, 4096))
    }

    @Test fun placeholdersAndRedirectsProveNothing() {
        assertFalse(DeleteHereGate.proves(ok206().copy(contentType = "text/html; charset=utf-8"), sha, 4096))
        assertFalse(DeleteHereGate.proves(ok206().copy(finalUrl = "https://cdn.example/404.jpg"), sha, 4096))
        for (status in listOf(404, 500, 302, 0)) assertFalse("$status", DeleteHereGate.proves(ok206().copy(status = status), sha, 4096))
    }

    @Test fun oneProvenCopyIsEnoughAndItFailsClosed() {
        assertEquals(DeleteHereGate.Decision.Allowed(listOf("https://a.example")),
            DeleteHereGate.decide(mapOf("https://a.example" to ok206(), "https://b.example" to null), sha, 4096))
        assertTrue(DeleteHereGate.decide(emptyMap(), sha, 4096) is DeleteHereGate.Decision.Refused)
        assertTrue(DeleteHereGate.decide(mapOf("https://a.example" to null), sha, 4096) is DeleteHereGate.Decision.Refused)
        assertTrue(DeleteHereGate.decide(mapOf("https://a.example" to ok206().copy(status = 404), "https://b.example" to null), sha, 4096) is DeleteHereGate.Decision.Refused)
        assertTrue(DeleteHereGate.decide(mapOf("https://a.example" to ok206()), sha, 0) is DeleteHereGate.Decision.Refused)
    }

    @Test fun thisDeviceNeverCountsButTheMacDoes() {
        assertEquals(listOf("https://mac.tail.ts.net", "https://a.example"),
            DeleteHereGate.candidates(listOf("http://127.0.0.1:3355", "https://phone.tail.ts.net", "https://mac.tail.ts.net", "https://a.example", "https://a.example", "nonsense"),
                ownHosts = setOf("phone.tail.ts.net")))
    }

    @Test fun listLivesBesideTheVaultInTheEnginesShape() {
        val vault = File(tmp.root, "db/blossom")
        vault.mkdirs()
        val owner = "0a".repeat(32)
        // The engine reads removed_here/<owner>.json beside the vault folder (haven-go removed_here.go).
        assertEquals(File(tmp.root, "db/removed_here/$owner.json").absolutePath, DeviceRemovedHashes.fileFor(owner.uppercase(), vault)?.absolutePath)
        assertNull(DeviceRemovedHashes.fileFor("../etc", vault))
        assertTrue(DeviceRemovedStore.add(sha.uppercase(), owner, vault))
        assertFalse(DeviceRemovedStore.add("not-a-hash", owner, vault))
        val text = File(tmp.root, "db/removed_here/$owner.json").readText()
        // A JSON number either way (Kotlin may write 1.79E9); the engine and Apple read both.
        assertTrue(text, Regex("""^\{"removed":\{"$sha":[0-9.eE+]+\}\}$""").matches(text))
        // What Apple writes (a fractional number) reads here too.
        File(tmp.root, "db/removed_here/$owner.json").writeText("""{"removed":{"$sha":1795790000.25,"${"cd".repeat(32)}":1795790001}}""")
        // A relaunch reads it back; another owner's list is separate.
        DeviceRemovedStore.reset()
        val other = "cd".repeat(32)
        assertEquals(emptyList<String>(), DeviceRemovedStore.list(owner, vault).keeping(listOf(other, sha)))
        File(tmp.root, "db/removed_here/$owner.json").writeText("""{"removed":{"$sha":1795790000.25}}""")
        DeviceRemovedStore.reset()
        assertEquals(listOf(other), DeviceRemovedStore.list(owner, vault).keeping(listOf(other, sha)))
        assertEquals(listOf(other, sha), DeviceRemovedStore.list("0b".repeat(32), vault).keeping(listOf(other, sha)))
        // Save to Vault takes it off.
        DeviceRemovedStore.remove(sha, owner, vault)
        DeviceRemovedStore.reset()
        assertFalse(DeviceRemovedStore.list(owner, vault).contains(sha))
    }

    @Test fun writeFailureRefusesTheDelete() {
        val owner = "0a".repeat(32)
        val db = File(tmp.root, "ro")
        db.mkdirs()
        File(db, "removed_here").writeText("a file where the folder should be")
        assertFalse(DeviceRemovedStore.add(sha, owner, File(db, "blossom")))
    }
}
