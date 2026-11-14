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
 * The vault phone itself has no home vault (it is the vault), so its Save copies used to queue no emoji note at all:
 * copy v2 then brought those blobs to the owner's other devices with no emoji note, and they showed in Media. Now the
 * note goes into this phone's own vault's `/files` on loopback, signed with this device's mesh key, never the account
 * key or its signer.
 */
class EmojiNoteOwnVaultTest {
    @get:Rule
    val tmp = TemporaryFolder()

    private val server = MockWebServer()
    private val sha = "c".repeat(64)
    private val owner = "a".repeat(64)
    private val mesh = "d".repeat(64)
    private val set = "30030:${"b".repeat(64)}:cats"
    private val signedKinds = CopyOnWriteArrayList<Int>()
    private val ownerSigned = CopyOnWriteArrayList<Int>()

    @After
    fun stop() = server.shutdown()

    private inner class FakeFiles(val okFor: (JsonObject) -> Pair<Boolean, String> = { true to "" }) : WebSocketListener() {
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
            if (msg[0].jsonPrimitive.content == "EVENT") {
                val ev = msg[1].jsonObject
                val (ok, why) = okFor(ev)
                webSocket.send("""["OK","${ev["id"]!!.jsonPrimitive.content}",$ok,"$why"]""")
            }
        }
    }

    /** A phone with no home vault (the vault phone), its own relay at [ownBase]. */
    private fun vaultPhone(ownBase: String?, active: Boolean = true): HomeVaultSender {
        val context = mockk<Context> { every { filesDir } returns tmp.newFolder() }
        val config = mockk<ConfigStore>()
        every { config.config } returns MutableStateFlow(HavenConfig(homeVaultNpub = null))
        return HomeVaultSender(context, config).apply {
            ownerHex = { owner }
            ownerIsActive = { active }
            signerIsLocal = { true }
            signer = { kind, _, _ -> ownerSigned += kind; """{"id":"owner"}""" }
            ownFilesBase = { ownBase }
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

    private val offer = HomeVaultSender.EmojiNoteOffer(sha, "image/png", 9, listOf(listOf("blobcat", "https://cdn.example.com/b.png")), listOf(set))

    private fun base() = server.url("/").toString().trimEnd('/')

    @Test
    fun `the vault phone's emoji note goes into its own files room, signed with the mesh key`() {
        val room = FakeFiles()
        server.enqueue(MockResponse().withWebSocketUpgrade(room))
        val phone = vaultPhone(base())
        assertEquals("taken, not left owed forever", setOf(sha), phone.queueEmojiNotes(listOf(offer)))
        runBlocking { phone.drain() }
        assertEquals("/files", server.takeRequest().path)
        val ev = room.got.single { it[0].jsonPrimitive.content == "EVENT" }[1].jsonObject
        assertEquals(1063, ev["kind"]!!.jsonPrimitive.int)
        assertEquals(mesh, ev["pubkey"]!!.jsonPrimitive.content)
        val note = EmojiNote.parse(ev)!!
        assertEquals(listOf(listOf("blobcat", "https://cdn.example.com/b.png")), note.codes)
        assertEquals(listOf(set), note.sets)
        assertTrue("the account signer never signs here", ownerSigned.isEmpty())
        assertEquals(0, phone.state.value.waiting)
    }

    @Test
    fun `refused before the vault knows its own mesh key, the note waits instead of being dropped`() {
        server.enqueue(MockResponse().withWebSocketUpgrade(FakeFiles(okFor = { false to "restricted: only this vault's paired devices write media notes" })))
        val phone = vaultPhone(base())
        assertEquals(setOf(sha), phone.queueEmojiNotes(listOf(offer)))
        runBlocking { phone.drain() }
        assertEquals(1, phone.state.value.waiting)
    }

    @Test
    fun `with an outside relay or another account active, nothing is taken and it stays owed`() {
        assertTrue(vaultPhone(null).queueEmojiNotes(listOf(offer)).isEmpty())
        assertTrue(vaultPhone(base(), active = false).queueEmojiNotes(listOf(offer)).isEmpty())
    }
}
