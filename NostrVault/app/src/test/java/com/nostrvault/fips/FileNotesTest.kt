package com.nostrvault.fips

import kotlinx.serialization.json.Json
import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.JsonPrimitive
import kotlinx.serialization.json.buildJsonArray
import kotlinx.serialization.json.buildJsonObject
import kotlinx.serialization.json.put
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

/**
 * NIP-94 file notes on the home vault's /files (RESEARCH plan §1-§2): the tags a device signs, what a reader accepts,
 * the live merge, and when a tile hides. Case for case with Apple's FileNoteTests.swift (Tara, step 2).
 */
class FileNotesTest {
    private val sha = "ab".repeat(32)
    private val other = "cd".repeat(32)
    private val owner = "11".repeat(32)
    private val phone = "22".repeat(32)
    private val pad = "33".repeat(32)

    private fun event(id: String, signer: String, at: Long, kind: Int, tags: List<List<String>>): JsonObject = buildJsonObject {
        put("id", id)
        put("pubkey", signer)
        put("created_at", at)
        put("kind", kind)
        put("tags", buildJsonArray { tags.forEach { t -> add(buildJsonArray { t.forEach { add(JsonPrimitive(it)) } }) } })
        put("content", "")
        put("sig", "s")
    }

    private fun note(
        id: String,
        signer: String = phone,
        sha: String = this.sha,
        at: Long = 100,
        extra: List<List<String>> = emptyList(),
        owner: String = this.owner,
        kind: Int = 1063,
    ) = event(id, signer, at, kind, listOf(listOf("x", sha), listOf("m", "image/jpeg"), listOf("size", "38091"), listOf("p", owner)) + extra)

    private fun deletion(id: String, of: List<String>, sha: String = this.sha, at: Long = 200, signer: String = pad) =
        event(id, signer, at, 5, of.map { listOf("e", it) } + listOf(listOf("k", "1063"), listOf("x", sha), listOf("p", owner)))

    // Tags

    @Test
    fun `tags name the blob, its type, size, owner and servers`() {
        val tags = FileNote.tags(sha.uppercase(), "image/jpeg", 38091, owner, listOf("https://nostr.build/", "https://blossom.band"))
        assertEquals(
            listOf(
                listOf("x", sha), listOf("m", "image/jpeg"), listOf("size", "38091"), listOf("p", owner),
                listOf("url", "https://nostr.build/$sha.jpg"),
                listOf("fallback", "https://blossom.band/$sha.jpg"),
                listOf("client", "nostr-vault"),
            ),
            tags,
        )
    }

    @Test
    fun `tags with no server name the vault only`() {
        val tags = FileNote.tags(sha, "video/mp4", 5, owner, emptyList())!!
        assertFalse(tags.any { it.first() == "url" || it.first() == "fallback" })
    }

    @Test
    fun `tags leave out mesh and home network servers`() {
        val tags = FileNote.tags(sha, "image/png", 5, owner, listOf("fipsmesh://npub1x/", "http://192.168.1.4:3355", "https://cdn.example.com"))!!
        assertEquals(listOf(listOf("url", "https://cdn.example.com/$sha.png")), tags.filter { it.first() == "url" })
        assertFalse(tags.any { it.first() == "fallback" })
    }

    @Test
    fun `tags refuse a bad hash, type, size or owner`() {
        assertNull(FileNote.tags("abc", "image/png", 1, owner, emptyList()))
        assertNull(FileNote.tags(sha, " ", 1, owner, emptyList()))
        assertNull(FileNote.tags(sha, "image/png", -1, owner, emptyList()))
        assertNull(FileNote.tags(sha, "image/png", 1, "npub1notahex", emptyList()))
    }

    @Test
    fun `deletion tags name every note, the kind, the hash and the owner`() {
        assertEquals(
            listOf(listOf("e", "n1"), listOf("e", "n2"), listOf("k", "1063"), listOf("x", sha), listOf("p", owner)),
            FileNoteDeletion.tags(listOf("n2", "n1", "n2"), sha, owner),
        )
        assertNull("a kind 5 here must name notes", FileNoteDeletion.tags(emptyList(), sha, owner))
    }

    // Parse

    @Test
    fun `parse reads a note`() {
        val n = FileNote.parse(note("n1", extra = listOf(listOf("url", "https://a.example/$sha.jpg"), listOf("fallback", "https://b.example/$sha"))))!!
        assertEquals("n1", n.id)
        assertEquals(phone, n.signer)
        assertEquals(sha, n.sha256)
        assertEquals("image/jpeg", n.mime)
        assertEquals(38091L, n.size)
        assertEquals(owner, n.owner)
        assertEquals(listOf("https://a.example/$sha.jpg", "https://b.example/$sha"), n.urls)
    }

    @Test
    fun `parse refuses bad notes`() {
        assertNull("x must be 64 lower-case hex", FileNote.parse(note("n", sha = "ABAB")))
        assertNull(FileNote.parse(note("n", sha = sha.uppercase())))
        assertNull(FileNote.parse(note("n", kind = 1)))
        assertNull(FileNote.parse(event("n", phone, 100, 1063, listOf(listOf("x", sha), listOf("m", "image/jpeg"), listOf("p", owner)))))
        assertNull("one p tag only", FileNote.parse(note("n", extra = listOf(listOf("p", pad)))))
        assertNull(FileNote.parse(note("", signer = phone)))
    }

    @Test
    fun `parse keeps only https links`() {
        val n = FileNote.parse(note("n", extra = listOf(listOf("url", "javascript:alert(1)"), listOf("fallback", "http://x.example/a"), listOf("fallback", "https://ok.example/$sha"))))!!
        assertEquals(listOf("https://ok.example/$sha"), n.urls)
    }

    @Test
    fun `parse of a deletion needs the kind tag and notes`() {
        assertEquals(setOf("n1", "n2"), FileNoteDeletion.parse(deletion("d1", listOf("n1", "n2")))!!.noteIds)
        assertNull(FileNoteDeletion.parse(event("d2", pad, 200, 5, listOf(listOf("e", "n1"), listOf("x", sha)))))
        assertNull(FileNoteDeletion.parse(deletion("d3", emptyList())))
    }

    @Test
    fun `parse reads a note off the wire`() {
        val wire = """{"id":"n1","pubkey":"$phone","created_at":1700000000,"kind":1063,"tags":[["x","$sha"],["m","image/png"],["size","9"],["p","$owner"]],"content":"","sig":"s"}"""
        val n = FileNote.parse(Json.parseToJsonElement(wire) as JsonObject)
        assertNotNull(n)
        assertEquals(1_700_000_000L, n!!.createdAt)
    }

    // Live merge

    @Test
    fun `a note for a new hash adds a tile`() {
        val state = FileNotesState()
        assertEquals(FileNotesState.Change.Added(sha), state.apply(note("n1")))
        assertEquals(listOf(sha), state.tiles.map { it.sha256 })
        assertEquals("the same note twice changes nothing", FileNotesState.Change.None, state.apply(note("n1")))
    }

    @Test
    fun `a second device's note for the same hash merges links`() {
        val state = FileNotesState()
        state.apply(note("n1", extra = listOf(listOf("url", "https://a.example/$sha"))))
        assertEquals(FileNotesState.Change.None, state.apply(note("n2", signer = pad, at = 150, extra = listOf(listOf("url", "https://b.example/$sha")))))
        assertEquals(1, state.tiles.size)
        assertEquals("newest note's links first", listOf("https://b.example/$sha", "https://a.example/$sha"), state.tiles[0].urls)
        assertEquals(setOf("n1", "n2"), state.noteIds(sha).toSet())
    }

    @Test
    fun `tiles are newest first`() {
        val state = FileNotesState()
        state.apply(note("n1", at = 100))
        state.apply(note("n2", sha = other, at = 300))
        assertEquals(listOf(other, sha), state.tiles.map { it.sha256 })
    }

    @Test
    fun `a deletion drops the tile only when no live note names the hash`() {
        val state = FileNotesState()
        state.apply(note("n1"))
        state.apply(note("n2", signer = pad))
        assertEquals("n2 still names it", FileNotesState.Change.None, state.apply(deletion("d1", listOf("n1"))))
        assertEquals(listOf(sha), state.tiles.map { it.sha256 })
        assertEquals(FileNotesState.Change.Removed(sha), state.apply(deletion("d2", listOf("n2"))))
        assertTrue(state.tiles.isEmpty())
    }

    @Test
    fun `a deleted note never comes back`() {
        val state = FileNotesState()
        state.apply(deletion("d1", listOf("n1")))
        assertEquals("the deletion came first (replay order)", FileNotesState.Change.None, state.apply(note("n1")))
        assertTrue(state.tiles.isEmpty())
        assertEquals("a re-upload is a new note and lands", FileNotesState.Change.Added(sha), state.apply(note("n3", at = 400)))
    }

    @Test
    fun `the owner filter keeps other accounts out`() {
        val state = FileNotesState(owner = owner)
        assertEquals(FileNotesState.Change.None, state.apply(note("n1", owner = pad)))
        assertTrue(state.tiles.isEmpty())
    }

    @Test
    fun `resubscribe since the newest seen with overlap`() {
        val state = FileNotesState()
        assertNull(state.since)
        state.apply(note("n1", at = 1_000))
        state.apply(deletion("d1", listOf("x"), at = 2_000))
        assertEquals(2_000 - FileNotesState.RESUBSCRIBE_OVERLAP, state.since)
    }

    @Test
    fun `the live filter asks for notes and deletions of the owner`() {
        assertEquals(Json.parseToJsonElement("""{"kinds":[1063,5],"#p":["$owner"]}"""), FileNote.liveFilter(owner, null))
        assertEquals(Json.parseToJsonElement("""{"kinds":[1063,5],"#p":["$owner"],"since":50}"""), FileNote.liveFilter(owner, 50))
    }

    // AUTH

    @Test
    fun `auth names the vault's mesh address over the mesh`() {
        assertEquals("ws://npub1vault.fips/files", FileNote.authRelayUrl("npub1vault", "ws://127.0.0.1:41234/sometoken/files"))
    }

    @Test
    fun `auth names the loopback url on the vault itself`() {
        assertEquals("wss://127.0.0.1:3355/files", FileNote.authRelayUrl(null, "wss://127.0.0.1:3355/files"))
    }

    @Test
    fun `the files url keeps the ingress token path`() {
        assertEquals("ws://127.0.0.1:41234/tok/files", FileNote.filesUrl("http://127.0.0.1:41234/tok"))
        assertEquals("wss://127.0.0.1:3355/files", FileNote.filesUrl("https://127.0.0.1:3355"))
    }

    // Tile check (gap 3)

    @Test
    fun `a tile hides only when every server says 404 and the vault lacks it`() {
        assertEquals(FileNote.TileState.HIDDEN, FileNote.tileState(listOf(404, 404), false))
        assertEquals("vault not asked: not proof", FileNote.TileState.DIMMED, FileNote.tileState(listOf(404, 404), null))
        assertEquals("unreachable is not gone", FileNote.TileState.DIMMED, FileNote.tileState(listOf(404, null), false))
        assertEquals(FileNote.TileState.VISIBLE, FileNote.tileState(listOf(404, 200), false))
        assertEquals(FileNote.TileState.VISIBLE, FileNote.tileState(emptyList(), true))
        assertEquals(FileNote.TileState.HIDDEN, FileNote.tileState(emptyList(), false))
        assertEquals(FileNote.TileState.DIMMED, FileNote.tileState(listOf(500), false))
    }
}
