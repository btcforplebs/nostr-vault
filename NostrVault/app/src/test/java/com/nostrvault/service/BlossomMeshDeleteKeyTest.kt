package com.nostrvault.service

import com.nostrvault.data.local.ConfigStore
import com.nostrvault.relay.HavenConfig
import io.mockk.every
import io.mockk.mockk
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.runBlocking
import okhttp3.mockwebserver.MockResponse
import okhttp3.mockwebserver.MockWebServer
import org.junit.After
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

/**
 * Delete everywhere over the mesh is signed by this device's mesh key: one delete naming every target and one get for
 * the HEAD (contract §2.1, Apple #1803). The owner's token only without a mesh key, or for a vault that refuses the
 * device form without X-Mesh-Devices (#1804), and then signed once.
 */
class BlossomMeshDeleteKeyTest {
    private val server = MockWebServer()
    private val sha = "d".repeat(64)
    private val npub = "npub1qgpqyqszqgpqyqszqgpqyqszqgpqyqszqgpqyqszqgpqyqszqgpq2yz0cn"
    private var ownerSigns = 0

    @After
    fun stop() = server.shutdown()

    private fun service(): BlossomService {
        val configStore = mockk<ConfigStore>(relaxed = true)
        every { configStore.config } returns MutableStateFlow(HavenConfig(ownerNpub = "npub1owner"))
        return BlossomService(configStore, mockk(relaxed = true), mockk(relaxed = true), mockk(relaxed = true), mockk(relaxed = true)).apply {
            meshIngress = { server.url("/tok").toString().trimEnd('/') }
            meshRetryDelayMs = 10
        }
    }

    private fun auth(device: Boolean) = MeshDeleteAuth(
        device = if (device) "dev-delete" else null,
        deviceCheck = if (device) "dev-get" else null,
        signOwner = { ownerSigns++; "owner" },
    )

    private fun requests(n: Int) = List(n) { server.takeRequest().let { "${it.method} ${it.getHeader("Authorization")}" } }

    @Test
    fun `the delete and its check use the mesh key`() = runBlocking {
        server.enqueue(MockResponse().setResponseCode(204))
        server.enqueue(MockResponse().setResponseCode(404))
        assertTrue(service().deleteOnMeshDevice(npub, sha, auth(device = true)))
        assertEquals(listOf("DELETE Nostr dev-delete", "HEAD Nostr dev-get"), requests(2))
        assertEquals(0, ownerSigns)
    }

    @Test
    fun `a vault with its paired set gets no owner token`() = runBlocking {
        server.enqueue(MockResponse().setResponseCode(401).addHeader("X-Mesh-Devices", "set"))
        server.enqueue(MockResponse().setResponseCode(200))
        assertFalse(service().deleteOnMeshDevice(npub, sha, auth(device = true)))
        assertEquals(2, server.requestCount)
        assertEquals(0, ownerSigns)
    }

    @Test
    fun `a vault without the set gets one owner retry`() = runBlocking {
        server.enqueue(MockResponse().setResponseCode(403))
        server.enqueue(MockResponse().setResponseCode(200))
        server.enqueue(MockResponse().setResponseCode(204))
        server.enqueue(MockResponse().setResponseCode(404))
        assertTrue(service().deleteOnMeshDevice(npub, sha, auth(device = true)))
        assertEquals(
            listOf("DELETE Nostr dev-delete", "HEAD Nostr dev-get", "DELETE Nostr owner", "HEAD Nostr owner"),
            requests(4),
        )
        assertEquals(1, ownerSigns)
    }

    @Test
    fun `without a mesh key the owner's token is signed once for every device`() = runBlocking {
        val a = auth(device = false)
        repeat(2) {
            server.enqueue(MockResponse().setResponseCode(204))
            server.enqueue(MockResponse().setResponseCode(404))
        }
        val svc = service()
        assertTrue(svc.deleteOnMeshDevice(npub, sha, a))
        assertTrue(svc.deleteOnMeshDevice(npub, sha, a))
        assertEquals(1, ownerSigns)
        assertEquals("DELETE Nostr owner", requests(1).single())
    }
}
