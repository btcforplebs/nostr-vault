package com.nostrvault.fips

import okhttp3.Request
import okhttp3.Response
import org.junit.After
import org.junit.Assert.assertArrayEquals
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Before
import org.junit.Test
import java.io.IOException
import java.security.MessageDigest

/**
 * iOS #1079 / #1080 / #1081 on Android: a photo tries its URL first and, when
 * that fails, the author's vaults over the FIPS mesh — up to three, each asked
 * again every second for up to 45 s, the photo giving up at 90 s — while the
 * views say "Loading image over FIPS…".
 */
class FipsMeshFallbackTest {
    private val author = "d".repeat(64)
    private val blob = "a photo kept on a home vault".toByteArray()
    private val sha = MessageDigest.getInstance("SHA-256").digest(blob).joinToString("") { "%02x".format(it) }
    private val url = "https://dead.example/$sha.jpg"

    // Each test gets vaults no other test has distrusted or marked unreachable.
    private val run = Integer.toHexString(System.nanoTime().toInt()).padStart(8, '0').map { BECH32[it.code % BECH32.length] }.joinToString("")
    private fun npub(c: Char) = "npub1" + (run + c.toString().repeat(58)).take(58)
    private companion object { const val BECH32 = "qpzry9x8gf2tvdw0s3jn54khce6mua7l" }
    private val v1 = npub('q')
    private val v2 = npub('z')
    private val v3 = npub('x')
    private val v4 = npub('w')

    private val dialled = mutableListOf<String>()
    private var now = 0L
    private val slept = mutableListOf<Long>()

    private lateinit var savedLists: () -> Map<String, List<String>>
    private lateinit var savedFollows: Set<String>
    private lateinit var savedDial: (String) -> String?
    private lateinit var savedRequest: (String) -> Unit
    private lateinit var savedClock: () -> Long
    private lateinit var savedSleep: (Long) -> Unit

    @Before fun setUp() {
        savedLists = FipsMediaRouter.serverLists
        savedFollows = FipsMediaRouter.follows
        savedDial = FipsMeshInterceptor.dial
        savedRequest = FipsMediaRouter.requestServerList
        savedClock = FipsMeshInterceptor.clock
        savedSleep = FipsMeshInterceptor.sleep
        FipsMediaRouter.requestServerList = {}
        FipsMediaRouter.follows = setOf(author)
        listVaults(v1, v2)
        // Each vault's loopback base is its npub, so the chain can tell who is asked.
        FipsMeshInterceptor.dial = { dialled += it; "http://127.0.0.1:9/$it" }
        FipsMeshInterceptor.clock = { now }
        FipsMeshInterceptor.sleep = { slept += it; now += it }
        MeshMediaStatus.clear(sha)
    }

    @After fun tearDown() {
        FipsMediaRouter.serverLists = savedLists
        FipsMediaRouter.follows = savedFollows
        FipsMeshInterceptor.dial = savedDial
        FipsMediaRouter.requestServerList = savedRequest
        FipsMeshInterceptor.clock = savedClock
        FipsMeshInterceptor.sleep = savedSleep
        MeshMediaStatus.clear(sha)
    }

    private fun listVaults(vararg npubs: String) {
        val list = listOf("https://blossom.example") + npubs.map { "fipsmesh://$it/" }
        FipsMediaRouter.serverLists = { mapOf(author to list) }
    }

    /** The vault a mesh request went to, or null for the URL itself. */
    private fun vaultOf(request: Request): String? =
        request.url.pathSegments.firstOrNull()?.takeIf { request.url.host == "127.0.0.1" }

    private fun read(chain: MeshTestChain): Response = FipsMeshInterceptor().intercept(chain)

    private fun request(u: String = url): Request =
        Request.Builder().url(u).tag(MeshAuthor::class.java, MeshAuthor(author)).build()

    @Test fun `a URL that works is used and the mesh is never asked`() {
        val chain = MeshTestChain(request()) { MeshTestChain.reply(it, 200, blob) }
        val got = read(chain)
        assertEquals(200, got.code)
        assertEquals(listOf(url), chain.sent)
        assertEquals(emptyList<String>(), dialled)
        assertNull(MeshMediaStatus.phases.value[sha])
    }

    @Test fun `a dead HTTPS URL loads over FIPS, checked against its hash`() {
        val chain = MeshTestChain(request()) { r -> if (vaultOf(r) == null) MeshTestChain.reset() else MeshTestChain.reply(r, 200, blob) }
        val got = read(chain)
        assertEquals(200, got.code)
        assertEquals("fips", got.header(FipsMeshInterceptor.VIA_HEADER))
        assertArrayEquals(blob, got.body!!.bytes())
        assertEquals("the photo keeps its own URL for the caches", url, got.request.url.toString())
        assertEquals(listOf(v1), dialled)
        assertNull("the spinner goes when the photo arrives", MeshMediaStatus.phases.value[sha])
    }

    @Test fun `an HTTP error from the URL falls back to the mesh too`() {
        val chain = MeshTestChain(request()) { r -> if (vaultOf(r) == null) MeshTestChain.reply(r, 404) else MeshTestChain.reply(r, 200, blob) }
        assertEquals("fips", read(chain).header(FipsMeshInterceptor.VIA_HEADER))
    }

    @Test fun `the views are told while the mesh is asked`() {
        var seen: MeshMediaPhase? = null
        val chain = MeshTestChain(request()) { r ->
            if (vaultOf(r) == null) MeshTestChain.reset()
            seen = MeshMediaStatus.phases.value[sha]
            MeshTestChain.reply(r, 200, blob)
        }
        read(chain)
        assertEquals(MeshMediaPhase.MeshLookup, seen)
        assertEquals("Loading image over FIPS…", MeshMediaPhase.MeshLookup.text())
    }

    @Test fun `a vault without the photo hands over to the next one the author lists`() {
        val chain = MeshTestChain(request()) { r ->
            when (vaultOf(r)) {
                null -> MeshTestChain.reset()
                v1 -> MeshTestChain.reply(r, 404)
                else -> MeshTestChain.reply(r, 200, blob)
            }
        }
        assertEquals("fips", read(chain).header(FipsMeshInterceptor.VIA_HEADER))
        assertEquals(listOf(v1, v2), dialled)
    }

    @Test fun `a vault whose route is still coming up is asked again every second`() {
        var tries = 0
        val chain = MeshTestChain(request()) { r ->
            when (vaultOf(r)) {
                null -> MeshTestChain.reset()
                else -> if (++tries < 4) MeshTestChain.reset() else MeshTestChain.reply(r, 200, blob)
            }
        }
        assertEquals("fips", read(chain).header(FipsMeshInterceptor.VIA_HEADER))
        assertEquals(listOf(v1, v1, v1, v1), dialled)
        assertEquals(listOf(1_000L, 1_000L, 1_000L), slept)
    }

    @Test fun `a vault that never answers is given 45 seconds, then the next is asked`() {
        val chain = MeshTestChain(request()) { r ->
            when (vaultOf(r)) {
                v2 -> MeshTestChain.reply(r, 200, blob)
                else -> MeshTestChain.reset()
            }
        }
        assertEquals("fips", read(chain).header(FipsMeshInterceptor.VIA_HEADER))
        assertEquals(v2, dialled.last())
        assertEquals("v1 was asked for 45 s, once a second", 46, dialled.count { it == v1 })
        assertEquals(45_000L, now)
    }

    @Test fun `one photo gives up after 90 seconds and says the vault could not be reached`() {
        listVaults(v1, v2, v3)
        val chain = MeshTestChain(request()) { MeshTestChain.reset() }
        try {
            read(chain)
            throw AssertionError("the URL's own failure comes back")
        } catch (e: IOException) {
            // expected: the URL's error, as before the mesh was asked
        }
        assertFalse("the third vault is past the photo's 90 s", v3 in dialled)
        assertEquals(90_000L, now)
        assertEquals(MeshMediaPhase.Unreached, MeshMediaStatus.phases.value[sha])
        assertEquals("Couldn't reach the owner's vault", MeshMediaPhase.Unreached.text())
    }

    @Test fun `no more than three vaults are asked for one photo`() {
        listVaults(v1, v2, v3, v4)
        val chain = MeshTestChain(request()) { r -> if (vaultOf(r) == null) MeshTestChain.reply(r, 404) else MeshTestChain.reply(r, 404) }
        assertEquals(404, read(chain).code)
        assertEquals(listOf(v1, v2, v3), dialled)
    }

    @Test fun `wrong bytes drop that vault for the session and the next is asked`() {
        val chain = MeshTestChain(request()) { r ->
            when (vaultOf(r)) {
                null -> MeshTestChain.reset()
                v1 -> MeshTestChain.reply(r, 200, "not the photo".toByteArray())
                else -> MeshTestChain.reply(r, 200, blob)
            }
        }
        assertEquals("fips", read(chain).header(FipsMeshInterceptor.VIA_HEADER))
        assertTrue(FipsMediaRouter.isDistrusted(v1))
        assertFalse(FipsMediaRouter.isDistrusted(v2))
    }

    @Test fun `an author the owner does not follow is never dialled`() {
        FipsMediaRouter.follows = emptySet()
        val chain = MeshTestChain(request()) { r -> MeshTestChain.reply(r, 404) }
        assertEquals(404, read(chain).code)
        assertEquals(emptyList<String>(), dialled)
        assertNull(MeshMediaStatus.phases.value[sha])
    }

    @Test fun `a photo that left the screen stops asking`() {
        lateinit var chain: MeshTestChain
        chain = MeshTestChain(request()) { r ->
            if (vaultOf(r) != null) chain.canceled = true
            MeshTestChain.reset()
        }
        try { read(chain) } catch (e: IOException) { }
        assertEquals(listOf(v1), dialled)
        assertNull("a cancelled load says nothing about the vault", MeshMediaStatus.phases.value[sha])
    }

    @Test fun `a fips link goes to the mesh first`() {
        val fipsUrl = "http://$v2.fips/$sha"
        val chain = MeshTestChain(request(fipsUrl)) { r -> MeshTestChain.reply(r, 200, blob) }
        assertEquals("fips", read(chain).header(FipsMeshInterceptor.VIA_HEADER))
        assertEquals(listOf(v2), dialled)
        assertFalse("the .fips URL itself is not fetched", fipsUrl in chain.sent)
    }

    @Test fun `the vault rule takes the first three listed, or only a listed fips host`() {
        assertEquals(listOf(v1, v2, v3), FipsMediaRouter.vaultsIn(listOf(v1, v2, v3, v4), null))
        assertEquals(listOf(v1, v2), FipsMediaRouter.vaultsIn(listOf(v1, v1, v2), null))
        assertEquals(listOf(v3), FipsMediaRouter.vaultsIn(listOf(v1, v2, v3), v3))
        assertEquals(emptyList<String>(), FipsMediaRouter.vaultsIn(listOf(v1, v2), v4))
    }
}
