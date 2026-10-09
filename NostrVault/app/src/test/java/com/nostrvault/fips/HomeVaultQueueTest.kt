package com.nostrvault.fips

import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Rule
import org.junit.Test
import org.junit.rules.TemporaryFolder

class HomeVaultQueueTest {
    @get:Rule
    val tmp = TemporaryFolder()

    private val kiosk = "npub1" + "q".repeat(58)
    private val self = "npub1" + "p".repeat(58)
    private val sha = "a".repeat(64)

    @Test
    fun `a queue survives a restart, in order`() {
        val dir = tmp.newFolder()
        HomeVaultQueue(dir).apply {
            assertTrue(addBlob(sha, "image/jpeg", 5, now = 1) { it.writeText("bytes") })
            assertTrue(addEvent("e1", """{"id":"e1"}""", now = 2))
        }
        val reopened = HomeVaultQueue(dir)
        assertEquals(listOf(sha, "e1"), reopened.items().map { it.key })
        assertEquals("bytes", reopened.blobFile(sha).readText())
        assertEquals("image/jpeg", reopened.items()[0].contentType)
    }

    @Test
    fun `the same thing queued twice is one item`() {
        val q = HomeVaultQueue(tmp.newFolder())
        q.addEvent("e1", "{}")
        q.addEvent("e1", "{}")
        q.addBlob(sha, "image/png", 1) { it.writeText("x") }
        q.addBlob(sha, "image/png", 1) { it.writeText("x") }
        assertEquals(2, q.size)
    }

    @Test
    fun `removing a blob deletes its bytes`() {
        val q = HomeVaultQueue(tmp.newFolder())
        q.addBlob(sha, "image/png", 1) { it.writeText("x") }
        q.remove(sha)
        assertEquals(0, q.size)
        assertFalse(q.blobFile(sha).exists())
    }

    @Test
    fun `a blob whose copy fails is not queued`() {
        val q = HomeVaultQueue(tmp.newFolder())
        assertFalse(q.addBlob(sha, "image/png", 1) { throw java.io.IOException("disk full") })
        assertEquals(0, q.size)
        assertFalse(q.blobFile(sha).exists())
    }

    @Test
    fun `clear empties the queue and the blobs`() {
        val q = HomeVaultQueue(tmp.newFolder())
        q.addBlob(sha, "image/png", 1) { it.writeText("x") }
        q.addEvent("e1", "{}")
        q.clear()
        assertEquals(0, q.size)
        assertFalse(q.blobFile(sha).exists())
    }

    @Test
    fun `candidates are the owner's mesh entries, not this phone`() {
        val list = listOf(
            "https://blossom.example.com",
            "fipsmesh://$self/",
            "fipsmesh://$kiosk/",
            "fipsmesh://$kiosk/",
            "fipsmesh://$kiosk:80/",
        )
        assertEquals(listOf(kiosk), HomeVaultRules.candidates(list, ownMeshNpub = self))
        assertEquals(listOf(self, kiosk), HomeVaultRules.candidates(list, ownMeshNpub = null))
    }

    @Test
    fun `an event OK is sent, refused for good, or retried`() {
        assertEquals(HomeVaultSend.SENT, HomeVaultRules.eventOutcome(true, ""))
        assertEquals(HomeVaultSend.SENT, HomeVaultRules.eventOutcome(false, "duplicate: have it"))
        assertEquals(HomeVaultSend.RETRY, HomeVaultRules.eventOutcome(false, "rate-limited: slow down"))
        assertEquals(HomeVaultSend.RETRY, HomeVaultRules.eventOutcome(false, "error: db"))
        assertEquals(HomeVaultSend.REJECTED, HomeVaultRules.eventOutcome(false, "blocked: not the owner"))
        assertEquals(HomeVaultSend.REJECTED, HomeVaultRules.eventOutcome(false, "invalid: bad sig"))
    }

    @Test
    fun `an upload status is sent, refused for good, or retried`() {
        assertEquals(HomeVaultSend.SENT, HomeVaultRules.uploadOutcome(200))
        assertEquals(HomeVaultSend.SENT, HomeVaultRules.uploadOutcome(201))
        assertEquals(HomeVaultSend.REJECTED, HomeVaultRules.uploadOutcome(403))
        assertEquals(HomeVaultSend.REJECTED, HomeVaultRules.uploadOutcome(413))
        assertEquals(HomeVaultSend.RETRY, HomeVaultRules.uploadOutcome(404))
        assertEquals(HomeVaultSend.RETRY, HomeVaultRules.uploadOutcome(502))
    }

    @Test
    fun `publishing 10063 keeps every mesh entry, after the public servers`() {
        val other = "npub1" + "z".repeat(58)
        val newest = listOf("fipsmesh://$kiosk/", "https://old.example", "fipsmesh://$other/")
        assertEquals(
            listOf("https://new.example", "fipsmesh://$kiosk/", "fipsmesh://$other/"),
            HomeVaultRules.mergeServerList(newest, listOf("https://new.example")),
        )
        // Nothing published yet.
        assertEquals(listOf("https://a.example"), HomeVaultRules.mergeServerList(emptyList(), listOf("https://a.example")))
    }

    @Test
    fun `a sender lists its home vault and drops the one it replaced`() {
        val other = "npub1" + "z".repeat(58)
        val newest = listOf("https://a.example", "fipsmesh://$kiosk/", "fipsmesh://$self/")
        assertEquals(
            listOf("https://a.example", "fipsmesh://$self/", "fipsmesh://$other/"),
            HomeVaultRules.mergeServerList(newest, listOf("https://a.example"), homeVault = other, dropMesh = kiosk),
        )
        // Already listed: once.
        assertEquals(
            listOf("https://a.example", "fipsmesh://$kiosk/", "fipsmesh://$self/"),
            HomeVaultRules.mergeServerList(newest, listOf("https://a.example"), homeVault = kiosk),
        )
    }

    @Test
    fun `a pasted or scanned mesh address`() {
        assertEquals(kiosk, HomeVaultRules.meshNpubFromInput(kiosk))
        assertEquals(kiosk, HomeVaultRules.meshNpubFromInput(" nostr:$kiosk\n"))
        assertEquals(kiosk, HomeVaultRules.meshNpubFromInput("fipsmesh://$kiosk/"))
        assertEquals(kiosk, HomeVaultRules.meshNpubFromInput("fipsmesh://$kiosk"))
        assertNull(HomeVaultRules.meshNpubFromInput("https://$kiosk/"))
        assertNull(HomeVaultRules.meshNpubFromInput("npub1short"))
        assertNull(HomeVaultRules.meshNpubFromInput(""))
    }

    @Test
    fun `a kiosk-only blob is published under the first public https server`() {
        val private = setOf("https://192.168.1.5:4443")
        val mirrors = listOf("https://192.168.1.5:4443", "http://plain.example", "https://blossom.example/", "https://b2.example")
        assertEquals("https://blossom.example", HomeVaultRules.publicServerFor(mirrors) { it in private })
        assertEquals(null, HomeVaultRules.publicServerFor(listOf("https://192.168.1.5:4443")) { it in private })
        assertEquals(null, HomeVaultRules.publicServerFor(emptyList()) { false })
    }

    @Test
    fun `a pending public copy survives a restart and carries no bytes`() {
        val dir = tmp.newFolder()
        assertTrue(HomeVaultQueue(dir).addPublicCopy(sha, "video/mp4", "https://blossom.example"))
        val item = HomeVaultQueue(dir).items().single()
        assertEquals(HomeVaultQueue.TYPE_PUBLIC_COPY, item.type)
        assertEquals("video/mp4", item.contentType)
        // The server the note names travels with it: only that one counts.
        assertEquals("https://blossom.example", item.server)
        assertFalse(HomeVaultQueue(dir).blobFile(sha).exists())
    }

    @Test
    fun `auth-required waits, restricted is final`() {
        assertEquals(HomeVaultSend.RETRY, HomeVaultRules.eventOutcome(false, "auth-required: log in"))
        assertEquals(
            HomeVaultSend.REJECTED,
            HomeVaultRules.eventOutcome(false, "restricted: the mesh accepts only the owner's own events"),
        )
    }

    @Test
    fun `backoff doubles from a minute and stops at six hours`() {
        assertEquals(60_000L, HomeVaultRules.backoffMs(1))
        assertEquals(120_000L, HomeVaultRules.backoffMs(2))
        assertEquals(6 * 60 * 60_000L, HomeVaultRules.backoffMs(12))
        assertEquals(6 * 60 * 60_000L, HomeVaultRules.backoffMs(1000))
    }

    @Test
    fun `an item too old or tried too often is given up on`() {
        val now = 100L * 24 * 60 * 60_000L
        val fresh = HomeVaultQueue.Item(key = "k", type = HomeVaultQueue.TYPE_EVENT, queuedAt = now - 1000)
        assertFalse(HomeVaultRules.expired(fresh, now))
        assertTrue(HomeVaultRules.expired(fresh.copy(attempts = 1, queuedAt = now - HomeVaultRules.MAX_AGE_MS - 1), now))
        // Never tried: the wall clock alone (jumped forward, set by hand) must not empty the queue.
        assertFalse(HomeVaultRules.expired(fresh.copy(queuedAt = now - HomeVaultRules.MAX_AGE_MS - 1), now))
        assertTrue(HomeVaultRules.expired(fresh.copy(attempts = HomeVaultRules.MAX_ATTEMPTS), now))
    }

    @Test
    fun `a full queue refuses more, by count and by bytes`() {
        val byCount = HomeVaultQueue(tmp.newFolder(), maxItems = 2)
        assertTrue(byCount.addEvent("e1", "{}"))
        assertTrue(byCount.addEvent("e2", "{}"))
        assertFalse(byCount.addEvent("e3", "{}"))
        assertFalse(byCount.addBlob(sha, "image/png", 1) { it.writeText("x") })
        assertEquals(2, byCount.size)

        val byBytes = HomeVaultQueue(tmp.newFolder(), maxBlobBytes = 10)
        assertTrue(byBytes.addBlob(sha, "image/png", 5) { it.writeText("12345") })
        val other = "b".repeat(64)
        assertFalse(byBytes.addBlob(other, "image/png", 6) { it.writeText("123456") })
        assertFalse(byBytes.blobFile(other).exists())
        assertFalse(java.io.File(byBytes.blobFile(other).path + ".part").exists())
    }

    @Test
    fun `a retry is recorded on the item`() {
        val q = HomeVaultQueue(tmp.newFolder())
        q.addEvent("e1", "{}")
        q.update(q.items().single().copy(attempts = 3, nextAt = 42))
        assertEquals(3, q.items().single().attempts)
        assertEquals(42L, q.items().single().nextAt)
    }

    @Test
    fun `a corrupt list is set aside and its blobs are not orphaned`() {
        val dir = tmp.newFolder()
        HomeVaultQueue(dir).addBlob(sha, "image/png", 1) { it.writeText("x") }
        java.io.File(dir, "queue.json").writeText("{not json")
        val q = HomeVaultQueue(dir)
        assertEquals(0, q.size)
        assertFalse(q.blobFile(sha).exists())
        assertTrue(java.io.File(dir, "queue.json.corrupt").exists())
    }

    @Test
    fun `blob files with no item are swept on open`() {
        val dir = tmp.newFolder()
        java.io.File(dir, "blobs").mkdirs()
        val stray = java.io.File(dir, "blobs/" + "c".repeat(64)).apply { writeText("x") }
        HomeVaultQueue(dir)
        assertFalse(stray.exists())
    }

    @Test
    fun `an oversized blob is refused before a byte is copied`() {
        val q = HomeVaultQueue(tmp.newFolder(), maxBlobBytes = 10)
        var copied = false
        assertFalse(q.addBlob(sha, "video/mp4", 11) { copied = true; it.writeText("x") })
        assertFalse(copied)
        assertEquals(0, q.size)
    }

    private fun item(key: String, type: String = HomeVaultQueue.TYPE_BLOB, nextAt: Long = 0) =
        HomeVaultQueue.Item(key = key, type = type, nextAt = nextAt)

    @Test
    fun `send now prompts an external signer at most the cap per tap`() {
        val items = (1..25).map { item("b$it") } + item("e1", HomeVaultQueue.TYPE_EVENT)
        val sel = HomeVaultRules.select(
            items, now = 0, userInitiated = true, localSigner = false,
            needsSignature = { it.type == HomeVaultQueue.TYPE_BLOB },
        )
        assertEquals(HomeVaultRules.PROMPTS_PER_TAP, sel.toTry.count { it.type == HomeVaultQueue.TYPE_BLOB })
        assertEquals(listOf("b1", "b2"), sel.toTry.take(2).map { it.key })
        // Already-signed events need no prompt and are never held back.
        assertTrue(sel.toTry.any { it.key == "e1" })
        assertTrue(sel.heldForSigner)
    }

    @Test
    fun `a background pass never prompts and respects backoff`() {
        val items = listOf(item("b1"), item("e1", HomeVaultQueue.TYPE_EVENT), item("e2", HomeVaultQueue.TYPE_EVENT, nextAt = 100))
        val external = HomeVaultRules.select(items, 50, false, false, { it.type == HomeVaultQueue.TYPE_BLOB })
        assertEquals(listOf("e1"), external.toTry.map { it.key })
        assertTrue(external.heldForSigner)
        val local = HomeVaultRules.select(items, 50, false, true, { it.type == HomeVaultQueue.TYPE_BLOB })
        assertEquals(listOf("b1", "e1"), local.toTry.map { it.key })
        assertFalse(local.heldForSigner)
        // Send now ignores backoff.
        assertEquals(3, HomeVaultRules.select(items, 50, true, true, { false }).toTry.size)
    }

    @Test
    fun `the same blob published under two servers gets a copy for each`() {
        val q = HomeVaultQueue(tmp.newFolder())
        assertTrue(q.addPublicCopy(sha, "image/png", "https://a.example"))
        assertTrue(q.addPublicCopy(sha, "image/png", "https://a.example"))
        assertTrue(q.addPublicCopy(sha, "image/png", "https://b.example"))
        assertEquals(listOf("https://a.example", "https://b.example"), q.items().map { it.server })
        assertEquals(listOf(sha, sha), q.items().map { HomeVaultQueue.shaOf(it.key) })
    }
}

