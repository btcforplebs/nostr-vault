package com.nostrvault.fips

import android.content.Context
import android.util.Base64
import com.nostrvault.data.local.ConfigStore
import com.nostrvault.relay.HavenConfig
import io.mockk.every
import io.mockk.mockk
import io.mockk.mockkStatic
import io.mockk.unmockkStatic
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.runBlocking
import okhttp3.OkHttpClient
import okhttp3.mockwebserver.MockResponse
import okhttp3.mockwebserver.MockWebServer
import org.junit.After
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Before
import org.junit.Rule
import org.junit.Test
import org.junit.rules.TemporaryFolder

/**
 * Sends to the home vault are signed by this phone's mesh key for that vault (contract §2.1, Apple #1803). The owner's
 * form only without a mesh key, or once after a 401/403 that does not carry X-Mesh-Devices (#1804).
 */
class HomeVaultSenderMeshKeyTest {
    @get:Rule
    val tmp = TemporaryFolder()

    private val server = MockWebServer()
    private val vault = "npub1qgpqyqszqgpqyqszqgpqyqszqgpqyqszqgpqyqszqgpqyqszqgpq2yz0cn"
    private val sha = "c".repeat(64)
    private val minted = mutableListOf<Pair<MeshKeyAuth.Verb, String>>()
    private val ownerSigned = mutableListOf<List<List<String>>>()

    @Before
    fun base64() {
        mockkStatic(Base64::class)
        every { Base64.encodeToString(any(), any()) } answers { java.util.Base64.getEncoder().encodeToString(firstArg<ByteArray>()) }
    }

    @After
    fun stop() {
        unmockkStatic(Base64::class)
        server.shutdown()
    }

    private fun sender(meshKey: Boolean, localSigner: Boolean = true): HomeVaultSender {
        val context = mockk<Context> { every { filesDir } returns tmp.newFolder() }
        val config = mockk<ConfigStore>()
        every { config.config } returns MutableStateFlow(HavenConfig(homeVaultNpub = vault))
        return HomeVaultSender(context, config).apply {
            ownerHex = { "a".repeat(64) }
            ownerIsActive = { true }
            signerIsLocal = { localSigner }
            meshToken = { verb, _, receiver, _, _, _ ->
                if (meshKey) { minted += verb to receiver; "device-${verb.wire}" } else null
            }
            signer = { _, _, tags -> ownerSigned += tags; """{"id":"owner"}""" }
        }
    }

    private fun queueWithBlob(): Pair<HomeVaultQueue, HomeVaultQueue.Item> {
        val q = HomeVaultQueue(tmp.newFolder())
        q.addBlob(sha, "image/png", 3) { it.writeBytes(byteArrayOf(1, 2, 3)) }
        return q to q.items().single()
    }

    private fun send(s: HomeVaultSender): HomeVaultSend {
        val (q, item) = queueWithBlob()
        return runBlocking { s.sendBlob(server.url("/tok").toString().trimEnd('/'), item, q, vault, OkHttpClient()) }
    }

    private fun auths(n: Int) = List(n) { server.takeRequest().let { "${it.method} ${it.getHeader("Authorization")}" } }

    @Test
    fun `the check and the upload use the mesh key for this vault, never the owner's`() {
        server.enqueue(MockResponse().setResponseCode(404))
        server.enqueue(MockResponse().setResponseCode(200))
        assertEquals(HomeVaultSend.SENT, send(sender(meshKey = true)))
        assertEquals(listOf("HEAD Nostr device-get", "PUT Nostr device-upload"), auths(2))
        assertEquals(listOf(MeshKeyAuth.Verb.GET to vault, MeshKeyAuth.Verb.UPLOAD to vault), minted)
        assertEquals(emptyList<Any>(), ownerSigned)
    }

    @Test
    fun `a vault that has its paired set refuses for good`() {
        server.enqueue(MockResponse().setResponseCode(404))
        server.enqueue(MockResponse().setResponseCode(401).addHeader("X-Mesh-Devices", "set"))
        val outcome = send(sender(meshKey = true))
        assertEquals(listOf("HEAD Nostr device-get", "PUT Nostr device-upload"), auths(2))
        assertEquals(2, server.requestCount)
        assertEquals(emptyList<Any>(), ownerSigned)
        assertEquals(HomeVaultRules.uploadOutcome(401), outcome)
    }

    @Test
    fun `a vault without the set gets one owner retry`() {
        server.enqueue(MockResponse().setResponseCode(404))
        server.enqueue(MockResponse().setResponseCode(403))
        server.enqueue(MockResponse().setResponseCode(200))
        assertEquals(HomeVaultSend.SENT, send(sender(meshKey = true)))
        val seen = auths(3)
        assertEquals(listOf("HEAD Nostr device-get", "PUT Nostr device-upload"), seen.take(2))
        assertEquals("PUT", seen[2].substringBefore(' '))
        assertEquals(1, ownerSigned.size)
        assertEquals(listOf("t", "upload"), ownerSigned.single().first())
    }

    @Test
    fun `without a mesh key the owner's form is used`() {
        server.enqueue(MockResponse().setResponseCode(404))
        server.enqueue(MockResponse().setResponseCode(200))
        assertEquals(HomeVaultSend.SENT, send(sender(meshKey = false)))
        assertEquals(2, ownerSigned.size) // the check and the upload
        assertNull(minted.firstOrNull())
    }

    // A bunker or Amber is never asked for a mesh send (build 26: lane photos held for a tap since Nov 8).

    @Test
    fun `with a remote signer and no mesh key the blob waits, nothing asks the owner`() {
        server.enqueue(MockResponse().setResponseCode(404))
        assertEquals(HomeVaultSend.RETRY, send(sender(meshKey = false, localSigner = false)))
        assertEquals("only the unsigned check went out", 1, server.requestCount)
        assertEquals(emptyList<Any>(), ownerSigned)
    }

    @Test
    fun `with a remote signer a vault without the set gets no owner retry`() {
        server.enqueue(MockResponse().setResponseCode(404))
        server.enqueue(MockResponse().setResponseCode(403))
        val outcome = send(sender(meshKey = true, localSigner = false))
        assertEquals(listOf("HEAD Nostr device-get", "PUT Nostr device-upload"), auths(2))
        assertEquals(2, server.requestCount)
        assertEquals(emptyList<Any>(), ownerSigned)
        assertEquals(HomeVaultRules.uploadOutcome(403), outcome)
    }
}
