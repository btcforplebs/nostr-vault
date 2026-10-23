package com.nostrvault.fips

import com.nostrvault.di.AppModule
import com.nostrvault.service.LocalBlossomCache
import okhttp3.Request
import okhttp3.mockwebserver.Dispatcher
import okhttp3.mockwebserver.MockResponse
import okhttp3.mockwebserver.MockWebServer
import okhttp3.mockwebserver.RecordedRequest
import okio.Buffer
import org.junit.After
import org.junit.Assert.assertArrayEquals
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Before
import org.junit.Test
import java.security.MessageDigest

/**
 * The fallback through Coil's real HTTP client ([AppModule.imageHttpClient]), every interceptor in place: a photo
 * whose HTTPS server is gone loads from the author's vault. The vault's loopback ingress is a local server here,
 * as FipsBridge.ingress hands one back on a phone.
 */
class FipsMeshImageClientTest {
    private val author = "e".repeat(64)
    private val vault = "npub1" + "7".repeat(58)
    private val blob = "kept at home, gone from the web".toByteArray()
    private val sha = MessageDigest.getInstance("SHA-256").digest(blob).joinToString("") { "%02x".format(it) }

    private val server = MockWebServer()
    private lateinit var savedLists: () -> Map<String, List<String>>
    private lateinit var savedFollows: Set<String>
    private lateinit var savedDial: (String) -> String?
    private var savedLocalCache = true

    @Before fun setUp() {
        server.dispatcher = object : Dispatcher() {
            override fun dispatch(request: RecordedRequest): MockResponse =
                if (request.path == "/$sha") MockResponse().setBody(Buffer().write(blob)) else MockResponse().setResponseCode(404)
        }
        server.start()
        savedLists = FipsMediaRouter.serverLists
        savedFollows = FipsMediaRouter.follows
        savedDial = FipsMeshInterceptor.dial
        FipsMediaRouter.follows = setOf(author)
        FipsMediaRouter.serverLists = { mapOf(author to listOf("fipsmesh://$vault/")) }
        // The phone's local Blossom cache is not part of this read, and its probe of 127.0.0.1 is remembered
        // across tests: left on, it rewrites the URL here and its cached answer breaks LocalBlossomCacheTest.
        savedLocalCache = LocalBlossomCache.enabled
        LocalBlossomCache.enabled = false
        FipsMeshInterceptor.dial = { if (it == vault) server.url("/").toString().trimEnd('/') else null }
    }

    @After fun tearDown() {
        FipsMediaRouter.serverLists = savedLists
        FipsMediaRouter.follows = savedFollows
        FipsMeshInterceptor.dial = savedDial
        LocalBlossomCache.enabled = savedLocalCache
        server.shutdown()
        MeshMediaStatus.clear(sha)
    }

    @Test fun `a photo on a dead HTTPS host loads over FIPS through the image client`() {
        // .invalid never resolves (RFC 6761): the HTTPS fetch fails as a deleted host's would.
        val url = "https://gone.invalid/$sha.jpg"
        val request = Request.Builder().url(url).tag(MeshAuthor::class.java, MeshAuthor(author)).build()
        AppModule.imageHttpClient().newCall(request).execute().use { response ->
            assertEquals(200, response.code)
            assertEquals("fips", response.header(FipsMeshInterceptor.VIA_HEADER))
            assertArrayEquals(blob, response.body!!.bytes())
            assertEquals(url, response.request.url.toString())
        }
        assertEquals("/$sha", server.takeRequest().path)
        assertNull(MeshMediaStatus.phases.value[sha])
        println("PROOF: https://gone.invalid/${sha.take(8)}….jpg failed over HTTPS and was read over FIPS from ${vault.take(12)}")
    }
}
