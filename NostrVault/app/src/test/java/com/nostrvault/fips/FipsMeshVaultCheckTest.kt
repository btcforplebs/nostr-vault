package com.nostrvault.fips

import okhttp3.Request
import okhttp3.Response
import org.junit.After
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Before
import org.junit.Test

/**
 * #988 (Tron, PR 984 review): a `.fips` photo URL names a node in its host, and anyone can write any npub there. A read
 * dials that node only when the author's own 10063 lists it, else nothing (same rule as iOS vaults(for:serverList:)).
 */
class FipsMeshVaultCheckTest {
    private val author = "a".repeat(64)
    private val vault = "npub1" + "q".repeat(58)
    private val second = "npub1" + "z".repeat(58)
    private val stranger = "npub1" + "p".repeat(58)
    private val sha = "b".repeat(64)

    private val dialled = mutableListOf<String>()
    private lateinit var saved: Triple<() -> Map<String, List<String>>, Set<String>, (String) -> String?>
    private lateinit var savedRequest: (String) -> Unit
    private lateinit var savedClock: () -> Long
    private lateinit var savedSleep: (Long) -> Unit
    private var now = 0L

    @Before fun setUp() {
        saved = Triple(FipsMediaRouter.serverLists, FipsMediaRouter.follows, FipsMeshInterceptor.dial)
        savedRequest = FipsMediaRouter.requestServerList
        savedClock = FipsMeshInterceptor.clock
        savedSleep = FipsMeshInterceptor.sleep
        FipsMediaRouter.requestServerList = {}
        FipsMediaRouter.follows = setOf(author)
        FipsMediaRouter.serverLists = { mapOf(author to listOf("https://blossom.example", "fipsmesh://$vault/", "fipsmesh://$second/")) }
        // Record the node and answer nothing: the read then falls through to the URL, as when a vault is unreachable.
        FipsMeshInterceptor.dial = { dialled += it; null }
        // The patience loop runs on a fake clock: a dead vault costs no real time.
        FipsMeshInterceptor.clock = { now }
        FipsMeshInterceptor.sleep = { now += it }
    }

    @After fun tearDown() {
        FipsMediaRouter.serverLists = saved.first
        FipsMediaRouter.follows = saved.second
        FipsMeshInterceptor.dial = saved.third
        FipsMediaRouter.requestServerList = savedRequest
        FipsMeshInterceptor.clock = savedClock
        FipsMeshInterceptor.sleep = savedSleep
    }

    @Test fun `a host the author lists is dialled, even when it is not the first`() {
        assertEquals(listOf(second), FipsMediaRouter.vaultsFor(author, "$second.fips"))
        read("http://$second.fips/$sha")
        assertEquals(setOf(second), dialled.toSet())
    }

    @Test fun `a host the author does not list dials nothing, not even their own vault`() {
        assertEquals(emptyList<String>(), FipsMediaRouter.vaultsFor(author, "$stranger.fips"))
        read("http://$stranger.fips/$sha.jpg")
        assertEquals(emptyList<String>(), dialled)
    }

    @Test fun `a plain https URL that fails reads from the vaults the author lists, in order`() {
        assertEquals(listOf(vault, second), FipsMediaRouter.vaultsFor(author, "blossom.example"))
        read("https://blossom.example/$sha", urlCode = 404)
        assertEquals(listOf(vault, second), dialled.distinct())
    }

    @Test fun `a plain https URL that works never dials the mesh`() {
        read("https://blossom.example/$sha", urlCode = 200)
        assertEquals(emptyList<String>(), dialled)
    }

    @Test fun `no list for the author yet dials nothing`() {
        FipsMediaRouter.serverLists = { emptyMap() }
        assertNull(FipsMediaRouter.vaultsFor(author, "$vault.fips"))
        read("http://$vault.fips/$sha")
        assertEquals(emptyList<String>(), dialled)
    }

    /** One GET through the interceptor, tagged with the note's author as the image loader tags it. */
    private fun read(url: String, urlCode: Int = 200): Response {
        val request = Request.Builder().url(url).tag(MeshAuthor::class.java, MeshAuthor(author)).build()
        val response = FipsMeshInterceptor().intercept(MeshTestChain(request) { MeshTestChain.reply(it, urlCode) })
        assertEquals("the read falls through to the URL itself", url, response.request.url.toString())
        return response
    }
}
