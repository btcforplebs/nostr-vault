package com.nostrvault.fips

import org.junit.Assert.assertEquals
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
            assertTrue(addBlob(sha, "image/jpeg", now = 1) { it.writeText("bytes") })
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
        q.addBlob(sha, "image/png") { it.writeText("x") }
        q.addBlob(sha, "image/png") { it.writeText("x") }
        assertEquals(2, q.size)
    }

    @Test
    fun `removing a blob deletes its bytes`() {
        val q = HomeVaultQueue(tmp.newFolder())
        q.addBlob(sha, "image/png") { it.writeText("x") }
        q.remove(sha)
        assertEquals(0, q.size)
        assertFalse(q.blobFile(sha).exists())
    }

    @Test
    fun `a blob whose copy fails is not queued`() {
        val q = HomeVaultQueue(tmp.newFolder())
        assertFalse(q.addBlob(sha, "image/png") { throw java.io.IOException("disk full") })
        assertEquals(0, q.size)
        assertFalse(q.blobFile(sha).exists())
    }

    @Test
    fun `clear empties the queue and the blobs`() {
        val q = HomeVaultQueue(tmp.newFolder())
        q.addBlob(sha, "image/png") { it.writeText("x") }
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
}
