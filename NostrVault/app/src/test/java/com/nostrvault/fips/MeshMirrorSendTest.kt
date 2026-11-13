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
import okhttp3.mockwebserver.MockResponse
import okhttp3.mockwebserver.MockWebServer
import org.junit.After
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Before
import org.junit.Rule
import org.junit.Test
import org.junit.rules.TemporaryFolder
import java.io.File
import java.util.concurrent.TimeUnit

/**
 * The feed Mirror's mesh step (Logen 2026-11-11, "if in the 10063"): only devices the owner's 10063 lists as
 * fipsmesh:// get the blob, each is reported, and nothing is signed with the account key.
 */
class MeshMirrorSendTest {
    @get:Rule
    val tmp = TemporaryFolder()

    private val server = MockWebServer()
    private val vault = "npub1qgpqyqszqgpqyqszqgpqyqszqgpqyqszqgpqyqszqgpqyqszqgpq2yz0cn"
    private val sha = "d".repeat(64)
    private val ownerSigned = mutableListOf<List<List<String>>>()
    private lateinit var filesDir: File

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

    private fun sender(meshKey: Boolean = true, owner: Boolean = true, reachable: Boolean = true): HomeVaultSender {
        filesDir = tmp.newFolder()
        val context = mockk<Context> { every { filesDir } returns this@MeshMirrorSendTest.filesDir }
        val config = mockk<ConfigStore>()
        every { config.config } returns MutableStateFlow(HavenConfig(homeVaultNpub = vault))
        return HomeVaultSender(context, config).apply {
            ownerHex = { "a".repeat(64) }
            ownerIsActive = { owner }
            signerIsLocal = { true }
            meshToken = { verb, _, _, _, _, _ -> if (meshKey) "device-${verb.wire}" else null }
            signer = { _, _, tags -> ownerSigned += tags; """{"id":"owner"}""" }
            meshIngress = { if (reachable) server.url("/").toString().trimEnd('/') else null }
        }
    }

    private fun blob() = tmp.newFile().apply { writeBytes(byteArrayOf(1, 2, 3)) }

    private fun queued(): List<HomeVaultQueue.Item> = HomeVaultQueue(File(filesDir, "home_vault_queue")).items()

    private fun mirror(s: HomeVaultSender, listed: Set<String>) = runBlocking { s.offerMirror(sha, "image/png", blob(), listed) }

    private fun next() = server.takeRequest(1, TimeUnit.SECONDS)

    @Test
    fun `a listed vault gets it with the device key and is reported sent`() {
        server.enqueue(MockResponse().setResponseCode(404))
        server.enqueue(MockResponse().setResponseCode(200))
        val results = mirror(sender(), setOf(vault))
        assertEquals(listOf(MeshMirrorResult(vault, DeviceRole.HOME_VAULT, MeshMirrorOutcome.SENT)), results)
        assertEquals("HEAD Nostr device-get", next()!!.let { "${it.method} ${it.getHeader("Authorization")}" })
        assertEquals("PUT Nostr device-upload", next()!!.let { "${it.method} ${it.getHeader("Authorization")}" })
        assertEquals(emptyList<Any>(), ownerSigned)
        assertEquals(emptyList<Any>(), queued())
    }

    @Test
    fun `no 10063 entry for the vault means no mesh send`() {
        val results = mirror(sender(), emptySet())
        assertEquals(emptyList<Any>(), results)
        assertEquals(0, server.requestCount)
        assertEquals(emptyList<Any>(), queued())
    }

    @Test
    fun `another account active sends nothing`() {
        assertEquals(emptyList<Any>(), mirror(sender(owner = false), setOf(vault)))
        assertEquals(0, server.requestCount)
    }

    @Test
    fun `without a mesh key it waits and never signs as the owner`() {
        server.enqueue(MockResponse().setResponseCode(404))
        val results = mirror(sender(meshKey = false), setOf(vault))
        assertEquals(MeshMirrorOutcome.WAITING, results.single().outcome)
        val head = next()!!
        assertEquals("HEAD", head.method)
        assertNull(head.getHeader("Authorization"))
        assertNull(next())
        assertEquals(emptyList<Any>(), ownerSigned)
        assertTrue(queued().single().meshKeyOnly)
    }

    @Test
    fun `a refusal is final, with no owner-key retry`() {
        server.enqueue(MockResponse().setResponseCode(404))
        server.enqueue(MockResponse().setResponseCode(403)) // no X-Mesh-Devices: a post upload would retry as the owner
        val results = mirror(sender(), setOf(vault))
        assertEquals(MeshMirrorOutcome.REFUSED, results.single().outcome)
        assertEquals(2, server.requestCount)
        assertEquals(emptyList<Any>(), ownerSigned)
    }

    @Test
    fun `an unreachable vault keeps it queued and says waiting`() {
        val results = mirror(sender(reachable = false), setOf(vault))
        assertEquals(MeshMirrorOutcome.WAITING, results.single().outcome)
        assertEquals(0, server.requestCount)
        assertEquals(sha, queued().single().key)
    }

    @Test
    fun `listed npubs come from fipsmesh entries only`() {
        assertEquals(
            setOf(vault),
            MeshMirrorSend.listedNpubs(listOf("https://blossom.example.com", "fipsmesh://$vault/", "fipsmesh://not-an-npub/")),
        )
    }

    @Test
    fun `no mesh blob is held for an external signer`() {
        val item = HomeVaultQueue.Item(key = sha, type = HomeVaultQueue.TYPE_BLOB, meshKeyOnly = true)
        val owner = item.copy(meshKeyOnly = false)
        val selection = HomeVaultRules.select(
            listOf(item, owner), now = 0, userInitiated = false, localSigner = false,
            needsSignature = HomeVaultRules::needsOwnerSignature,
        )
        assertEquals("both sign with the mesh key; a remote signer is never asked", listOf(item, owner), selection.toTry)
        assertFalse(selection.heldForSigner)
        assertFalse(HomeVaultQueue.Item(key = sha, type = HomeVaultQueue.TYPE_BLOB).meshKeyOnly)
    }
}
