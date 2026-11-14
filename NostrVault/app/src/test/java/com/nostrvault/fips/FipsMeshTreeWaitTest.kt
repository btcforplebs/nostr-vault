package com.nostrvault.fips

import okhttp3.Request
import org.junit.After
import org.junit.Assert.assertEquals
import org.junit.Assert.assertThrows
import org.junit.Assert.assertTrue
import org.junit.Before
import org.junit.Test
import java.io.IOException
import java.security.MessageDigest

/**
 * Logen 2026-11-14 (routing audit): right after the engine starts it has no tree parent (libnvfips -10). That was
 * remembered for 30 s like a dead vault, so every photo failed at once. Now a read waits for the tree within its
 * patience (iOS MeshMediaRouter.patientGet).
 */
class FipsMeshTreeWaitTest {
    private val author = "c".repeat(64)
    private val blob = "a photo the tree has to find first".toByteArray()
    private val sha = MessageDigest.getInstance("SHA-256").digest(blob).joinToString("") { "%02x".format(it) }
    private val url = "https://dead.example/$sha.jpg"
    private val vault = "npub1" + "t".repeat(58)

    private var noTreeAsks = 0
    private var dials = 0
    private var now = 0L
    private val slept = mutableListOf<Long>()

    private lateinit var savedLists: () -> Map<String, List<String>>
    private lateinit var savedFollows: Set<String>
    private lateinit var savedDial: (String) -> String?
    private lateinit var savedTreeWait: (String) -> Boolean
    private lateinit var savedRequest: (String) -> Unit
    private lateinit var savedClock: () -> Long
    private lateinit var savedSleep: (Long) -> Unit

    @Before fun setUp() {
        savedLists = FipsMediaRouter.serverLists
        savedFollows = FipsMediaRouter.follows
        savedDial = FipsMeshInterceptor.dial
        savedTreeWait = FipsMeshInterceptor.treeWait
        savedRequest = FipsMediaRouter.requestServerList
        savedClock = FipsMeshInterceptor.clock
        savedSleep = FipsMeshInterceptor.sleep
        FipsMediaRouter.requestServerList = {}
        FipsMediaRouter.follows = setOf(author)
        FipsMediaRouter.serverLists = { mapOf(author to listOf("https://blossom.example", "fipsmesh://$vault/")) }
        // The engine answers "no tree yet" [noTreeAsks] times, then opens the door.
        FipsMeshInterceptor.dial = {
            dials++
            lastWasNoTree = noTreeAsks > 0
            if (lastWasNoTree) { noTreeAsks--; null } else "http://127.0.0.1:9/$it"
        }
        FipsMeshInterceptor.treeWait = { lastWasNoTree }
        FipsMeshInterceptor.clock = { now }
        FipsMeshInterceptor.sleep = { slept += it; now += it }
        MeshMediaStatus.clear(sha)
    }

    /** Whether the last dial was answered "no tree yet" (what FipsMediaRouter.waitingForTree reports live). */
    private var lastWasNoTree = false

    @After fun tearDown() {
        FipsMediaRouter.serverLists = savedLists
        FipsMediaRouter.follows = savedFollows
        FipsMeshInterceptor.dial = savedDial
        FipsMeshInterceptor.treeWait = savedTreeWait
        FipsMediaRouter.requestServerList = savedRequest
        FipsMeshInterceptor.clock = savedClock
        FipsMeshInterceptor.sleep = savedSleep
        MeshMediaStatus.clear(sha)
    }

    private fun request(): Request = Request.Builder().url(url).tag(MeshAuthor::class.java, MeshAuthor(author)).build()

    private fun chain() = MeshTestChain(request()) { r ->
        if (r.url.host != "127.0.0.1") MeshTestChain.reset() else MeshTestChain.reply(r, 200, blob)
    }

    private fun noTreeFor(asks: Int) {
        noTreeAsks = asks
    }

    @Test fun `a photo waits for the tree parent and then loads over the mesh`() {
        noTreeFor(3)
        val got = FipsMeshInterceptor().intercept(chain())
        assertEquals("fips", got.header(FipsMeshInterceptor.VIA_HEADER))
        assertEquals("asked again until the tree was there", 4, dials)
        assertEquals(List(3) { FipsMeshInterceptor.TREE_POLL_MS }, slept)
    }

    @Test fun `a tree that never comes still ends the read within its patience`() {
        noTreeFor(Int.MAX_VALUE)
        // The mesh gave up: the URL's own failure is what the image loader sees.
        assertThrows(IOException::class.java) { FipsMeshInterceptor().intercept(chain()) }
        assertTrue("waited: $now", now >= FipsMeshInterceptor.READ_PATIENCE_MS)
        assertTrue("but not past it: $now", now < FipsMeshInterceptor.READ_PATIENCE_MS + FipsMeshInterceptor.TREE_POLL_MS + 1)
    }

    @Test fun `a vault that could not be dialled is not waited for`() {
        FipsMeshInterceptor.treeWait = { false }
        FipsMeshInterceptor.dial = { dials++; null }
        assertThrows(IOException::class.java) { FipsMeshInterceptor().intercept(chain()) }
        assertEquals(1, dials)
        assertEquals(emptyList<Long>(), slept)
    }
}
