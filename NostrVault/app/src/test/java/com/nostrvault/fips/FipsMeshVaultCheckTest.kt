package com.nostrvault.fips

import okhttp3.Call
import okhttp3.Connection
import okhttp3.Interceptor
import okhttp3.Protocol
import okhttp3.Request
import okhttp3.Response
import okhttp3.ResponseBody.Companion.toResponseBody
import org.junit.After
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Before
import org.junit.Test
import java.util.concurrent.TimeUnit

/**
 * #988 (Tron, PR 984 review): a `.fips` photo URL names a node in its host, and anyone can write any npub there. A read
 * dials that node only when the author's own 10063 lists it, else nothing (same rule as iOS vault(for:serverList:)).
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

    @Before fun setUp() {
        saved = Triple(FipsMediaRouter.serverLists, FipsMediaRouter.follows, FipsMeshInterceptor.dial)
        savedRequest = FipsMediaRouter.requestServerList
        FipsMediaRouter.requestServerList = {}
        FipsMediaRouter.follows = setOf(author)
        FipsMediaRouter.serverLists = { mapOf(author to listOf("https://blossom.example", "fipsmesh://$vault/", "fipsmesh://$second/")) }
        // Record the node and answer nothing: the read then falls through to the URL, as when a vault is unreachable.
        FipsMeshInterceptor.dial = { dialled += it; null }
    }

    @After fun tearDown() {
        FipsMediaRouter.serverLists = saved.first
        FipsMediaRouter.follows = saved.second
        FipsMeshInterceptor.dial = saved.third
        FipsMediaRouter.requestServerList = savedRequest
    }

    @Test fun `a host the author lists is dialled, even when it is not the first`() {
        assertEquals(second, FipsMediaRouter.vaultFor(author, "$second.fips"))
        read("http://$second.fips/$sha")
        assertEquals(listOf(second), dialled)
    }

    @Test fun `a host the author does not list dials nothing, not even their own vault`() {
        assertNull(FipsMediaRouter.vaultFor(author, "$stranger.fips"))
        read("http://$stranger.fips/$sha.jpg")
        assertEquals(emptyList<String>(), dialled)
    }

    @Test fun `a plain https URL reads from the first vault the author lists`() {
        assertEquals(vault, FipsMediaRouter.vaultFor(author, "blossom.example"))
        read("https://blossom.example/$sha")
        assertEquals(listOf(vault), dialled)
    }

    @Test fun `no list for the author yet dials nothing`() {
        FipsMediaRouter.serverLists = { emptyMap() }
        read("http://$vault.fips/$sha")
        assertEquals(emptyList<String>(), dialled)
    }

    /** One GET through the interceptor, tagged with the note's author as the image loader tags it. */
    private fun read(url: String): Response {
        val request = Request.Builder().url(url).tag(MeshAuthor::class.java, MeshAuthor(author)).build()
        val response = FipsMeshInterceptor().intercept(FakeChain(request))
        assertEquals("the read falls through to the URL itself", url, response.request.url.toString())
        return response
    }

    private class FakeChain(private val request: Request) : Interceptor.Chain {
        override fun request(): Request = request
        override fun proceed(request: Request): Response = Response.Builder()
            .request(request).protocol(Protocol.HTTP_1_1).code(200).message("OK").body("".toResponseBody()).build()
        override fun connection(): Connection? = null
        override fun call(): Call = throw UnsupportedOperationException()
        override fun connectTimeoutMillis(): Int = 0
        override fun withConnectTimeout(timeout: Int, unit: TimeUnit): Interceptor.Chain = this
        override fun readTimeoutMillis(): Int = 0
        override fun withReadTimeout(timeout: Int, unit: TimeUnit): Interceptor.Chain = this
        override fun writeTimeoutMillis(): Int = 0
        override fun withWriteTimeout(timeout: Int, unit: TimeUnit): Interceptor.Chain = this
    }
}
