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
 * the HEAD (contract §2.1, Apple #1803). Never the account key (Logen, 2026-11-19: fail closed).
 */
class BlossomMeshDeleteKeyTest {
    private val server = MockWebServer()
    private val sha = "d".repeat(64)
    private val npub = "npub1qgpqyqszqgpqyqszqgpqyqszqgpqyqszqgpqyqszqgpqyqszqgpq2yz0cn"

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
    )

    private fun requests(n: Int) = List(n) { server.takeRequest().let { "${it.method} ${it.getHeader("Authorization")}" } }

    @Test
    fun `the delete and its check use the mesh key`() = runBlocking {
        server.enqueue(MockResponse().setResponseCode(204))
        server.enqueue(MockResponse().setResponseCode(404))
        assertTrue(service().deleteOnMeshDevice(npub, sha, auth(device = true)))
        assertEquals(listOf("DELETE Nostr dev-delete", "HEAD Nostr dev-get"), requests(2))
    }

    @Test
    fun `a vault that refuses the mesh key gets no owner token, with or without its paired set`() = runBlocking {
        server.enqueue(MockResponse().setResponseCode(401).addHeader("X-Mesh-Devices", "set"))
        server.enqueue(MockResponse().setResponseCode(200))
        server.enqueue(MockResponse().setResponseCode(403))
        server.enqueue(MockResponse().setResponseCode(200))
        val svc = service()
        assertFalse(svc.deleteOnMeshDevice(npub, sha, auth(device = true)))
        assertFalse(svc.deleteOnMeshDevice(npub, sha, auth(device = true)))
        assertEquals(
            listOf("DELETE Nostr dev-delete", "HEAD Nostr dev-get", "DELETE Nostr dev-delete", "HEAD Nostr dev-get"),
            requests(4),
        )
    }

    @Test
    fun `without a mesh key nothing is sent and the device is left`() = runBlocking {
        assertFalse(service().deleteOnMeshDevice(npub, sha, auth(device = false)))
        assertEquals(0, server.requestCount)
    }
}
