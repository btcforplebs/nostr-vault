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
 * Sends to the home vault are signed by this phone's mesh key for that vault (contract §2.1, Apple #1803), never the
 * account key (Logen, 2026-11-19: fail closed). No mesh key, or a vault that refuses it: the blob waits (RETRY).
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
    fun `a vault that has its paired set and refuses keeps the blob waiting, no owner retry`() {
        server.enqueue(MockResponse().setResponseCode(404))
        server.enqueue(MockResponse().setResponseCode(401).addHeader("X-Mesh-Devices", "set"))
        assertEquals(HomeVaultSend.RETRY, send(sender(meshKey = true)))
        assertEquals(listOf("HEAD Nostr device-get", "PUT Nostr device-upload"), auths(2))
        assertEquals(2, server.requestCount)
        assertEquals(emptyList<Any>(), ownerSigned)
    }

    @Test
    fun `a vault without the set that refuses keeps the blob waiting, no owner retry`() {
        server.enqueue(MockResponse().setResponseCode(404))
        server.enqueue(MockResponse().setResponseCode(403))
        assertEquals(HomeVaultSend.RETRY, send(sender(meshKey = true)))
        assertEquals(listOf("HEAD Nostr device-get", "PUT Nostr device-upload"), auths(2))
        assertEquals(2, server.requestCount)
        assertEquals(emptyList<Any>(), ownerSigned)
    }

    @Test
    fun `without a mesh key the blob waits, even with the account key on this phone`() {
        for (local in listOf(true, false)) {
            server.enqueue(MockResponse().setResponseCode(404))
            assertEquals(HomeVaultSend.RETRY, send(sender(meshKey = false, localSigner = local)))
            assertNull("the check went out unsigned", server.takeRequest().getHeader("Authorization"))
        }
        assertEquals("only the two unsigned checks went out", 2, server.requestCount)
        assertEquals(emptyList<Any>(), ownerSigned)
        assertNull(minted.firstOrNull())
    }
}
