package com.nostrvault.fips

import com.nostrvault.fips.MeshCopyFixtures.obj
import kotlinx.coroutines.runBlocking
import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.JsonPrimitive
import kotlinx.serialization.json.jsonArray
import kotlinx.serialization.json.jsonPrimitive
import okhttp3.mockwebserver.MockResponse
import okhttp3.mockwebserver.MockWebServer
import org.junit.After
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Before
import org.junit.Test
import java.util.concurrent.TimeUnit

/** B's start against a stand-in A: the one NIP-98 start, the Bearer polls, and every way it can end. */
class MeshCopyClientTest {
    private lateinit var a: MockWebServer
    private val linkToken = "c".repeat(64)
    private val id = "a".repeat(32)
    private val token = "b".repeat(64)
    private val cases = MeshCopyFixtures.json("manifest-v2-cases.json")
    private val owner = cases["owner"]!!.jsonPrimitive.content
    private val ready = cases["cases"]!!.jsonArray[0].obj()["manifest"]!!.toString()
    private var signedTags: List<List<String>>? = null

    @Before fun up() { a = MockWebServer().apply { start() } }
    @After fun down() { a.shutdown() }

    private val link get() = "ws://${a.hostName}:${a.port}/$linkToken"
    private val client = MeshCopyClient(pollEveryMs = 1, buildWaitMs = 5_000)

    private fun start(free: Long = Long.MAX_VALUE, sign: String? = "Nostr signed") = runBlocking {
        client.start(link, owner, "Studio Mac", { free }) { tags -> signedTags = tags; sign }
    }

    private fun started() = MockResponse().setBody("""{"id":"$id","token":"$token","state":"building"}""")

    @Test
    fun `start, a build, then a ready manifest that fits`() {
        a.enqueue(started())
        a.enqueue(MockResponse().setResponseCode(409))
        a.enqueue(MockResponse().setBody(building()))
        a.enqueue(MockResponse().setBody(ready))
        val r = start()
        assertTrue(r.toString(), r is MeshCopyClient.Result.Ready)
        assertEquals(MeshCopyV2.Started(id, token), (r as MeshCopyClient.Result.Ready).started)

        val post = a.takeRequest(1, TimeUnit.SECONDS)!!
        assertEquals("POST", post.method)
        assertEquals("/$linkToken/copy/v2/start", post.path)
        assertEquals("Nostr signed", post.getHeader("Authorization"))
        assertEquals("close", post.getHeader("Connection"))
        // Signed for the path A checks; the link's own secret never goes into the event.
        assertEquals(listOf(listOf("u", "http://${a.hostName}:${a.port}/copy/v2/start"), listOf("method", "POST")), signedTags)
        assertFalse(signedTags!!.flatten().any { linkToken in it })
        repeat(3) {
            val get = a.takeRequest(1, TimeUnit.SECONDS)!!
            assertEquals("/$linkToken/copy/v2/$id", get.path)
            assertEquals("Bearer $token", get.getHeader("Authorization"))
        }
    }

    @Test
    fun `an A without the zip copy answers 404 and the relays carry the copy`() {
        a.enqueue(MockResponse().setResponseCode(404))
        assertEquals(MeshCopyClient.Result.NotServed, start())
    }

    @Test
    fun `refusals and A short of space`() {
        a.enqueue(MockResponse().setResponseCode(401))
        assertEquals(MeshCopyClient.Result.Failed("auth_refused", "Couldn't sign in to Studio Mac"), start())
        a.enqueue(MockResponse().setResponseCode(403))
        assertEquals("not_owner", (start() as MeshCopyClient.Result.Failed).code)
        a.enqueue(MockResponse().setResponseCode(507))
        val r = start() as MeshCopyClient.Result.Failed
        assertEquals("no_space", r.code)
        assertEquals(MeshCopyV2.Action.RELAYS, MeshCopyV2.action(r.code))
    }

    @Test
    fun `the signer saying no sends nothing`() {
        assertEquals("auth_refused", (start(sign = null) as MeshCopyClient.Result.Failed).code)
        assertEquals(0, a.requestCount)
    }

    @Test
    fun `short of space here stops before any chunk, with both sizes`() {
        a.enqueue(started())
        a.enqueue(MockResponse().setBody(ready))
        val r = start(free = 1L shl 29) as MeshCopyClient.Result.Failed
        assertEquals("needs_space", r.code)
        assertEquals("Needs 1.1 GB free, this device has 0.5 GB", r.line)
    }

    @Test
    fun `another account's manifest, a failed build and a gone copy`() {
        val other = (cases["cases"]!!.jsonArray.first { it.obj()["name"]!!.jsonPrimitive.content == "wrong owner" }).obj()["manifest"]!!
        a.enqueue(started())
        a.enqueue(MockResponse().setBody(other.toString()))
        assertEquals("wrong_owner", (start() as MeshCopyClient.Result.Failed).code)

        a.enqueue(started())
        a.enqueue(MockResponse().setBody(ready.replace("\"ready\"", "\"failed\"").replace("\"error\":\"\"", "\"error\":\"no_space\"")))
        assertEquals("no_space", (start() as MeshCopyClient.Result.Failed).code)

        a.enqueue(started())
        a.enqueue(MockResponse().setResponseCode(404))
        assertEquals("not_found", (start() as MeshCopyClient.Result.Failed).code)
    }

    @Test
    fun `an A that goes away is unreachable`() {
        a.shutdown()
        assertEquals("unreachable", (start() as MeshCopyClient.Result.Failed).code)
    }

    @Test
    fun `a start answer without a token is not taken`() {
        a.enqueue(MockResponse().setBody("""{"id":"$id","state":"building"}"""))
        assertEquals("bad_manifest", (start() as MeshCopyClient.Result.Failed).code)
        assertNull(MeshCopyV2.parseStart("{}"))
    }

    private fun building(): String {
        val o = cases["cases"]!!.jsonArray[0].obj()["manifest"]!!.obj()
        return JsonObject(o + ("state" to JsonPrimitive("building"))).toString()
    }
}
