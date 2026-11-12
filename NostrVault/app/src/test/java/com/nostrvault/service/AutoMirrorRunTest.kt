package com.nostrvault.service

import android.util.Base64
import com.nostrvault.data.local.ConfigStore
import com.nostrvault.data.local.VaultHistory
import com.nostrvault.data.local.VaultHistoryStore
import com.nostrvault.relay.HavenConfig
import io.mockk.coEvery
import io.mockk.every
import io.mockk.mockk
import io.mockk.mockkStatic
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.buildJsonArray
import kotlinx.serialization.json.buildJsonObject
import kotlinx.serialization.json.put
import okhttp3.mockwebserver.Dispatcher
import okhttp3.mockwebserver.MockResponse
import okhttp3.mockwebserver.MockWebServer
import okhttp3.mockwebserver.RecordedRequest
import okio.Buffer
import org.junit.After
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test
import java.io.File
import java.net.InetAddress
import java.nio.file.Files
import java.security.MessageDigest
import java.util.concurrent.ConcurrentHashMap
import java.util.concurrent.atomic.AtomicInteger

/**
 * Auto-Mirror's rules, run through the real [BlossomService.runMirror] /
 * [BlossomService.runAutoMirrorIfDue] against one fake server that is the
 * media server, the note links' host and this phone's vault (external relay
 * mode, so nothing touches a real relay on this machine):
 * 1 no download of a photo the vault has, 2 one signature per run,
 * 3 one run per 3 hours from the start, kept across a relaunch,
 * 4 at most 200 downloads per run, the rest next run.
 */
class AutoMirrorRunTest {
    private val owner = "f".repeat(64)

    /** Hash to bytes the server serves at `/<hash>`. */
    private val blobs = ConcurrentHashMap<String, ByteArray>()
    /** Note links (`/n/<name>.jpg`) to bytes. */
    private val noteFiles = ConcurrentHashMap<String, ByteArray>()
    /** What the media server lists as the owner's. */
    @Volatile private var listed: List<String> = emptyList()
    /** The vault: hashes stored (PUT /vault/upload adds). */
    private val vault: MutableSet<String> = ConcurrentHashMap.newKeySet()
    /** Every GET of a file, by path. */
    private val gets = ConcurrentHashMap<String, AtomicInteger>()
    private val signatures = AtomicInteger()
    @Volatile private var notes: List<JsonObject> = emptyList()

    private val dispatcher = object : Dispatcher() {
            override fun dispatch(request: RecordedRequest): MockResponse {
                val path = request.path.orEmpty()
                return when {
                    request.method == "GET" && path.startsWith("/list/") -> MockResponse().setBody(
                        listed.joinToString(",", "[", "]") { """{"sha256":"$it"}""" },
                    )
                    request.method == "PUT" && path == "/vault/upload" -> {
                        vault += sha(request.body.readByteArray())
                        MockResponse().setBody("{}")
                    }
                    request.method == "GET" -> {
                        gets.getOrPut(path) { AtomicInteger() }.incrementAndGet()
                        val bytes = blobs[path.removePrefix("/")] ?: noteFiles[path]
                        if (bytes == null) MockResponse().setResponseCode(404)
                        else MockResponse().setHeader("Content-Type", "image/jpeg").setBody(Buffer().write(bytes))
                    }
                    else -> MockResponse().setResponseCode(404)
                }
            }
        }

    /** Media server and note links, on IPv6 loopback: the note scan skips links on localhost / 127.0.0.1. */
    private val server = MockWebServer().apply { dispatcher = this@AutoMirrorRunTest.dispatcher; start(InetAddress.getByName("::1"), 0) }
    /** This phone's vault: an external relay may be plain http only on 127.0.0.1. */
    private val vaultServer = MockWebServer().apply { dispatcher = this@AutoMirrorRunTest.dispatcher; start(InetAddress.getByName("127.0.0.1"), 0) }
    private val base = "http://[::1]:${server.port}"
    private val stateDir: File = Files.createTempDirectory("automirror").toFile()

    init {
        mockkStatic(Base64::class)
        every { Base64.encodeToString(any(), any()) } returns "signed-auth-header"
        mockkStatic("com.nostrvault.service.NostrServiceSigningKt")
        every { any<NostrService>().isReadOnlyAccount() } returns false
    }

    @After fun stop() {
        server.shutdown()
        vaultServer.shutdown()
        stateDir.deleteRecursively()
    }

    private fun sha(bytes: ByteArray) =
        MessageDigest.getInstance("SHA-256").digest(bytes).joinToString("") { "%02x".format(it) }

    /** A blob on the media server; its hash. */
    private fun serverBlob(i: Int): String = "server blob $i".toByteArray().let { b -> sha(b).also { blobs[it] = b } }

    /** A note link with no hash in its name; the URL and the hash its bytes have. */
    private fun noteLink(name: String): Pair<String, String> {
        val bytes = "note file $name".toByteArray()
        noteFiles["/n/$name.jpg"] = bytes
        return "$base/n/$name.jpg" to sha(bytes)
    }

    private fun note(id: Int, content: String, tags: List<List<String>> = emptyList()) = buildJsonObject {
        put("id", id.toString().padStart(64, '0'))
        put("created_at", 1_700_000_000L + id)
        put("pubkey", owner)
        put("content", content)
        put("tags", buildJsonArray { tags.forEach { t -> add(buildJsonArray { t.forEach { add(kotlinx.serialization.json.JsonPrimitive(it)) } }) } })
    }

    private fun downloads(): Int = gets.values.sumOf { it.get() }

    /** One app launch: a fresh service over the same files on disk. */
    private fun launch(): BlossomService {
        val configStore = mockk<ConfigStore>(relaxed = true)
        every { configStore.config } returns MutableStateFlow(
            HavenConfig(
                ownerNpub = "npub1owner",
                blossomMirrors = listOf(base),
                useExternalRelay = true,
                externalRelayURL = "ws://127.0.0.1:${vaultServer.port}",
                externalBlossomURL = "http://127.0.0.1:${vaultServer.port}/vault",
            ),
        )
        val nostr = mockk<NostrService>(relaxed = true)
        every { nostr.ownerHexPubkey } returns owner
        coEvery { nostr.signEventAsync(any(), any(), any(), any(), any(), any(), any(), any()) } answers {
            signatures.incrementAndGet()
            NostrEvent(id = "e".repeat(64), pubkey = owner, createdAt = 1L, kind = 24242, tags = emptyList(), content = "", sig = "s".repeat(128))
        }
        // The note scan pages until a page has nothing new: the notes, then the same notes.
        coEvery { nostr.queryRawEvents(any(), any(), any(), any(), any()) } answers { notes }
        val cache = mockk<MediaCacheService>(relaxed = true)
        every { cache.isInLocalBlossom(any()) } answers { firstArg<String>() in vault }
        // Never written: a run that ends is not what holds the next one off.
        val history = mockk<VaultHistoryStore>(relaxed = true)
        every { history.state } returns MutableStateFlow(VaultHistory.Snapshot())
        return BlossomService(
            configStore, nostr, cache, history, mockk(relaxed = true),
            autoMirrorState = AutoMirrorState(stateDir),
        )
    }

    private fun BlossomService.awaitRun() {
        val until = System.currentTimeMillis() + 30_000
        while (mirrorRun.value.running) {
            check(System.currentTimeMillis() < until) { "mirror run did not finish" }
            Thread.sleep(20)
        }
    }

    // ── 1. never download a photo the vault has ──────────────────────────

    @Test fun `a photo the vault has is never downloaded, by any link`() {
        val had = serverBlob(1).also { vault += it }
        val missing = serverBlob(2)
        listed = listOf(had, missing)
        val (hashNamed, hashNamedSha) = "$base/$had.jpg" to had
        val (imetaUrl, imetaSha) = noteLink("imeta").also { vault += it.second }
        notes = listOf(note(1, "$hashNamed $imetaUrl", tags = listOf(listOf("imeta", "url $imetaUrl", "x $imetaSha"))))

        launch().apply { assertTrue(runMirror()); awaitRun() }

        assertEquals(hashNamedSha, had)
        assertEquals("only the one missing server file is fetched", mapOf("/$missing" to 1), gets.mapValues { it.value.get() })
    }

    @Test fun `a plain link fetched once is never fetched again, after a relaunch too`() {
        val (url, _) = noteLink("plain")
        notes = listOf(note(1, url))

        launch().apply { assertTrue(runMirror()); awaitRun() }
        assertEquals(1, gets["/n/plain.jpg"]?.get())

        launch().apply { assertTrue(runMirror()); awaitRun() }
        assertEquals("the vault has it now: no second download", 1, gets["/n/plain.jpg"]?.get())
    }

    @Test fun `two links to the same photo download it once`() {
        val (url, hash) = noteLink("same")
        val copy = "$base/n/same-copy.jpg"
        noteFiles["/n/same-copy.jpg"] = noteFiles.getValue("/n/same.jpg")
        notes = listOf(note(1, "$url $copy", tags = listOf(listOf("imeta", "url $url", "x $hash"), listOf("imeta", "url $copy", "x $hash"))))

        launch().apply { assertTrue(runMirror()); awaitRun() }

        assertEquals(1, downloads())
    }

    // ── 2. one signature per run ─────────────────────────────────────────

    @Test fun `server files and note links share one signature`() {
        listed = listOf(serverBlob(1), serverBlob(2))
        notes = listOf(note(1, noteLink("a").first), note(2, noteLink("b").first))

        launch().apply { assertTrue(runMirror()); awaitRun() }

        assertEquals("4 files fetched", 4, downloads())
        assertEquals(4, vault.size)
        assertEquals("one signature for the whole run", 1, signatures.get())
    }

    // ── 3. one run per 3 hours, from the start ───────────────────────────

    @Test fun `a relaunch mid-run does not start another run for 3 hours`() {
        val start = System.currentTimeMillis()
        assertTrue(launch().runAutoMirrorIfDue(now = start))

        // Killed before it finished: nothing marks it done. A new launch an hour later.
        val relaunched = launch()
        assertFalse(relaunched.runAutoMirrorIfDue(now = start + 60 * 60 * 1000))
        assertFalse(relaunched.runAutoMirrorIfDue(now = start + AutoMirrorRules.EVERY_MS - 1))
        relaunched.awaitRun()
        assertTrue(relaunched.runAutoMirrorIfDue(now = start + AutoMirrorRules.EVERY_MS))
        relaunched.awaitRun()
    }

    // ── 4. at most 200 per run, the rest next run ────────────────────────

    @Test fun `250 missing files download 200, then the other 50 next run`() {
        listed = (1..250).map(::serverBlob)

        launch().apply { assertTrue(runMirror()); awaitRun() }
        assertEquals(200, downloads())

        launch().apply { assertTrue(runMirror()); awaitRun() }
        assertEquals("the rest, each once", 250, downloads())
        assertTrue(gets.values.all { it.get() == 1 })
        assertEquals(250, vault.size)
    }

    @Test fun `the 200 is for the whole run, server files and note links together`() {
        listed = (1..190).map(::serverBlob)
        notes = (1..30).map { note(it, noteLink("n$it").first) }

        launch().apply { assertTrue(runMirror()); awaitRun() }

        assertEquals(200, downloads())
    }
}
