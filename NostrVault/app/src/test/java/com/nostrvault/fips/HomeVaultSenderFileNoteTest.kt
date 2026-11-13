package com.nostrvault.fips

import android.content.Context
import com.nostrvault.data.local.ConfigStore
import com.nostrvault.relay.HavenConfig
import io.mockk.every
import io.mockk.mockk
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.runBlocking
import kotlinx.serialization.json.Json
import kotlinx.serialization.json.JsonArray
import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.JsonPrimitive
import kotlinx.serialization.json.buildJsonArray
import kotlinx.serialization.json.buildJsonObject
import kotlinx.serialization.json.int
import kotlinx.serialization.json.jsonArray
import kotlinx.serialization.json.jsonObject
import kotlinx.serialization.json.jsonPrimitive
import kotlinx.serialization.json.put
import okhttp3.OkHttpClient
import okhttp3.Response
import okhttp3.WebSocket
import okhttp3.WebSocketListener
import okhttp3.mockwebserver.MockResponse
import okhttp3.mockwebserver.MockWebServer
import org.junit.After
import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Rule
import org.junit.Test
import org.junit.rules.TemporaryFolder
import java.util.concurrent.CopyOnWriteArrayList

/**
 * A queued file note reaches the home vault's /files signed with this device's mesh key at send time, never the
 * owner's signer: the 1063 for an add; for a delete an AUTH, a `#x` query, then one kind 5 naming every note found.
 * The relay's answer maps as the queue's other events do (accepted / duplicate done, restricted dropped).
 */
class HomeVaultSenderFileNoteTest {
    @get:Rule
    val tmp = TemporaryFolder()

    private val server = MockWebServer()
    private val vault = "npub1qgpqyqszqgpqyqszqgpqyqszqgpqyqszqgpqyqszqgpqyqszqgpq2yz0cn"
    private val sha = "c".repeat(64)
    private val owner = "a".repeat(64)
    private val mesh = "d".repeat(64)
    private val signedKinds = CopyOnWriteArrayList<Int>()
    private val ownerSigned = CopyOnWriteArrayList<Int>()

    @After
    fun stop() = server.shutdown()

    /** The room: AUTHs on connect, answers OKs with [okFor], a REQ with [stored]. Records what came in. */
    private inner class FakeFiles(
        val okFor: (JsonObject) -> Pair<Boolean, String> = { true to "" },
        val stored: List<JsonObject> = emptyList(),
    ) : WebSocketListener() {
        val got = CopyOnWriteArrayList<JsonArray>()
        override fun onOpen(webSocket: WebSocket, response: Response) {
            webSocket.send("""["AUTH","chal-1"]""")
        }

        override fun onClosing(webSocket: WebSocket, code: Int, reason: String) {
            webSocket.close(1000, null)
        }

        override fun onMessage(webSocket: WebSocket, text: String) {
            val msg = Json.parseToJsonElement(text).jsonArray
            got += msg
            when (msg[0].jsonPrimitive.content) {
                "AUTH", "EVENT" -> {
                    val ev = msg[1].jsonObject
                    val (ok, why) = okFor(ev)
                    webSocket.send("""["OK","${ev["id"]!!.jsonPrimitive.content}",$ok,"$why"]""")
                }
                "REQ" -> {
                    val sub = msg[1].jsonPrimitive.content
                    stored.forEach { webSocket.send("""["EVENT","$sub",$it]""") }
                    webSocket.send("""["EOSE","$sub"]""")
                }
            }
        }
    }

    private fun sender(): HomeVaultSender {
        val context = mockk<Context> { every { filesDir } returns tmp.newFolder() }
        val config = mockk<ConfigStore>()
        every { config.config } returns MutableStateFlow(HavenConfig(homeVaultNpub = vault))
        return HomeVaultSender(context, config).apply {
            ownerHex = { owner }
            ownerIsActive = { true }
            signerIsLocal = { true }
            signer = { kind, _, _ -> ownerSigned += kind; """{"id":"owner"}""" }
            fileNoteSign = { kind, tags ->
                signedKinds += kind
                buildJsonObject {
                    put("id", "$kind-${signedKinds.size}")
                    put("pubkey", mesh)
                    put("kind", kind)
                    put("created_at", 100)
                    put("tags", buildJsonArray { tags.forEach { t -> add(buildJsonArray { t.forEach { add(JsonPrimitive(it)) } }) } })
                    put("content", "")
                    put("sig", "s")
                }.toString()
            }
        }
    }

    private fun item(action: String): HomeVaultQueue.Item {
        val q = HomeVaultQueue(tmp.newFolder())
        q.addFileNote(HomeVaultQueue.FileNoteDraft(action, sha, "image/png", 9, listOf("https://cdn.example.com")))
        return q.items().single()
    }

    private fun send(room: FakeFiles, action: String): HomeVaultSend {
        server.enqueue(MockResponse().withWebSocketUpgrade(room))
        val base = server.url("/tok").toString().trimEnd('/')
        return runBlocking { sender().sendFileNote(base, item(action), vault, OkHttpClient()) }
    }

    private fun stored(id: String, x: String = sha) = Json.parseToJsonElement(
        """{"id":"$id","pubkey":"${"e".repeat(64)}","created_at":50,"kind":1063,"tags":[["x","$x"],["m","image/png"],["size","9"],["p","$owner"]],"content":"","sig":"s"}""",
    ).jsonObject

    @Test
    fun `an add sends a 1063 signed with the mesh key, on the files path, never the owner's signer`() {
        val room = FakeFiles()
        assertEquals(HomeVaultSend.SENT, send(room, HomeVaultQueue.FileNoteDraft.ADD))
        assertEquals("/tok/files", server.takeRequest().path)
        val ev = room.got.single { it[0].jsonPrimitive.content == "EVENT" }[1].jsonObject
        assertEquals(1063, ev["kind"]!!.jsonPrimitive.int)
        assertEquals(mesh, ev["pubkey"]!!.jsonPrimitive.content)
        val tags = ev["tags"]!!.jsonArray.map { t -> t.jsonArray.map { it.jsonPrimitive.content } }
        assertTrue(listOf("p", owner) in tags)
        assertTrue(listOf("url", "https://cdn.example.com/$sha.png") in tags)
        assertEquals(listOf(1063), signedKinds)
        assertTrue("the account signer never signs here", ownerSigned.isEmpty())
    }

    @Test
    fun `an emoji note is a 1063 with nv-emoji, its codes and sets, signed with the mesh key`() {
        val room = FakeFiles()
        val set = "30030:${"b".repeat(64)}:cats"
        val q = HomeVaultQueue(tmp.newFolder())
        q.offerEmojiDraft(set)
        server.enqueue(MockResponse().withWebSocketUpgrade(room))
        val base = server.url("/tok").toString().trimEnd('/')
        assertEquals(HomeVaultSend.SENT, runBlocking { sender().sendFileNote(base, q.items().single(), vault, OkHttpClient()) })
        val ev = room.got.single { it[0].jsonPrimitive.content == "EVENT" }[1].jsonObject
        assertEquals(mesh, ev["pubkey"]!!.jsonPrimitive.content)
        val parsed = EmojiNote.parse(ev)!!
        assertEquals(listOf(listOf("blobcat", "https://cdn.example.com/b.png")), parsed.codes)
        assertEquals(listOf(set), parsed.sets)
        assertTrue("the account signer never signs here", ownerSigned.isEmpty())
    }

    private fun HomeVaultQueue.offerEmojiDraft(set: String) = addFileNote(
        HomeVaultQueue.FileNoteDraft(
            HomeVaultQueue.FileNoteDraft.EMOJI, sha, "image/png", 9, emptyList(),
            listOf(listOf("blobcat", "https://cdn.example.com/b.png")), listOf(set),
        ),
    )

    @Test
    fun `a duplicate is done, restricted is dropped, an error waits`() {
        assertEquals(HomeVaultSend.SENT, send(FakeFiles(okFor = { false to "duplicate: this device already has a note for this file" }), HomeVaultQueue.FileNoteDraft.ADD))
        assertEquals(HomeVaultSend.REJECTED, send(FakeFiles(okFor = { false to "restricted: only this vault's paired devices write media notes" }), HomeVaultQueue.FileNoteDraft.ADD))
        assertEquals(HomeVaultSend.RETRY, send(FakeFiles(okFor = { false to "error: database busy" }), HomeVaultQueue.FileNoteDraft.ADD))
    }

    @Test
    fun `a delete AUTHs with the mesh key, finds every note for the blob, and sends one kind 5`() {
        val room = FakeFiles(stored = listOf(stored("n1"), stored("n2"), stored("n3", x = "f".repeat(64))))
        assertEquals(HomeVaultSend.SENT, send(room, HomeVaultQueue.FileNoteDraft.DELETE))
        val kinds = room.got.map { it[0].jsonPrimitive.content }
        assertEquals(listOf("AUTH", "REQ", "CLOSE", "EVENT"), kinds)
        val auth = room.got[0][1].jsonObject
        val authTags = auth["tags"]!!.jsonArray.map { t -> t.jsonArray.map { it.jsonPrimitive.content } }
        assertEquals(listOf(listOf("relay", "ws://$vault.fips/files"), listOf("challenge", "chal-1")), authTags)
        val filter = room.got[1][2].jsonObject
        assertEquals(listOf(sha), filter["#x"]!!.jsonArray.map { it.jsonPrimitive.content })
        val del = room.got[3][1].jsonObject
        assertEquals(5, del["kind"]!!.jsonPrimitive.int)
        val tags = del["tags"]!!.jsonArray.map { t -> t.jsonArray.map { it.jsonPrimitive.content } }
        assertEquals(
            "a note for another blob the room sent is not named",
            listOf(listOf("e", "n1"), listOf("e", "n2"), listOf("k", "1063"), listOf("x", sha), listOf("p", owner)),
            tags,
        )
        assertEquals(listOf(22242, 5), signedKinds)
        assertTrue(ownerSigned.isEmpty())
    }

    @Test
    fun `a delete with no note left is done without a kind 5`() {
        val room = FakeFiles()
        assertEquals(HomeVaultSend.SENT, send(room, HomeVaultQueue.FileNoteDraft.DELETE))
        assertTrue(room.got.none { it[0].jsonPrimitive.content == "EVENT" })
    }

    @Test
    fun `a delete whose AUTH the room refuses waits`() {
        val room = FakeFiles(okFor = { ev -> if (ev["kind"]!!.jsonPrimitive.int == 22242) false to "restricted: no" else true to "" })
        assertEquals(HomeVaultSend.RETRY, send(room, HomeVaultQueue.FileNoteDraft.DELETE))
        assertTrue(room.got.none { it[0].jsonPrimitive.content == "REQ" })
    }

    @Test
    fun `no mesh key yet waits, and never falls back to the owner`() {
        server.enqueue(MockResponse().withWebSocketUpgrade(FakeFiles()))
        val s = sender().apply { fileNoteSign = { _, _ -> null } }
        val base = server.url("/tok").toString().trimEnd('/')
        assertEquals(HomeVaultSend.RETRY, runBlocking { s.sendFileNote(base, item(HomeVaultQueue.FileNoteDraft.ADD), vault, OkHttpClient()) })
        assertTrue(ownerSigned.isEmpty())
    }
}
