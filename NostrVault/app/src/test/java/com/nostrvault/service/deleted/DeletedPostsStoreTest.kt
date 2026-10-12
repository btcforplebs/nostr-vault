package com.nostrvault.service.deleted

import com.nostrvault.service.EventPublisher
import kotlinx.serialization.json.Json
import kotlinx.serialization.json.jsonArray
import kotlinx.serialization.json.jsonObject
import kotlinx.serialization.json.jsonPrimitive
import kotlinx.serialization.json.long
import org.junit.After
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Before
import org.junit.Test
import java.io.File
import java.nio.file.Files

class DeletedPostsStoreTest {

    private val me = "a".repeat(64)
    private val other = "b".repeat(64)
    private val now = 1_800_000_000_000L
    private val day = 24L * 60 * 60 * 1000
    private lateinit var directory: File

    @Before
    fun setUp() {
        directory = File(Files.createTempDirectory("deleted-posts").toFile(), "store")
    }

    @After
    fun tearDown() {
        directory.parentFile?.deleteRecursively()
    }

    private fun post(
        id: String = "1".repeat(64),
        pubkey: String = me,
        tags: List<List<String>> = listOf(listOf("e", "9".repeat(64), "", "reply"), listOf("p", "8".repeat(64))),
        deletedAt: Long = now,
    ) = DeletedPost(
        id = id, pubkey = pubkey, createdAt = 1_700_000_000L, kind = 1, tags = tags,
        content = "vault delete test, ignore\nhttps://blossom.example/x.jpg",
        sig = "f".repeat(128), deletedAt = deletedAt,
    )

    // ── Round trip ──────────────────────────────────────────────

    /** A saved copy reads back field for field from a fresh store, as after a relaunch. */
    @Test
    fun `saved post reads back after relaunch`() {
        val saved = post()
        DeletedPostsStore(directory).save(saved, now)
        assertEquals(listOf(saved), DeletedPostsStore(directory).posts(me, now))
    }

    @Test
    fun `accounts do not see each other's posts`() {
        val store = DeletedPostsStore(directory)
        store.save(post(id = "1".repeat(64)), now)
        store.save(post(id = "2".repeat(64), pubkey = other), now)
        assertEquals(listOf("1".repeat(64)), store.posts(me, now).map { it.id })
        assertEquals(listOf("2".repeat(64)), store.posts(other, now).map { it.id })
    }

    @Test
    fun `remove drops only that post`() {
        val store = DeletedPostsStore(directory)
        val a = post(id = "1".repeat(64))
        val b = post(id = "2".repeat(64))
        store.save(a, now)
        store.save(b, now)
        store.remove(a.id, me)
        assertEquals(listOf(b), store.posts(me, now))
    }

    @Test
    fun `deleting the same id twice keeps one copy`() {
        val store = DeletedPostsStore(directory)
        store.save(post(deletedAt = now - day), now)
        store.save(post(deletedAt = now), now)
        assertEquals(listOf(now), store.posts(me, now).map { it.deletedAt })
    }

    @Test
    fun `account that is not a pubkey is never written`() {
        val store = DeletedPostsStore(directory)
        store.save(post(pubkey = "../../escape"), now)
        assertEquals(emptyList<DeletedPost>(), store.posts("../../escape", now))
        assertFalse(directory.exists())
    }

    // ── 30-day expiry ───────────────────────────────────────────

    @Test
    fun `posts older than thirty days expire`() {
        val store = DeletedPostsStore(directory)
        val fresh = post(id = "1".repeat(64), deletedAt = now - 29 * day)
        val stale = post(id = "2".repeat(64), deletedAt = now - 31 * day)
        store.save(fresh, now - 31 * day)
        store.save(stale, now - 31 * day)
        assertEquals(listOf(fresh), store.posts(me, now))
        // Gone from disk too, not only hidden.
        assertEquals(listOf(fresh), DeletedPostsStore(directory).posts(me, now - 31 * day))
    }

    @Test
    fun `most recently deleted comes first`() {
        val older = post(id = "1".repeat(64), deletedAt = now - 2 * day)
        val newer = post(id = "2".repeat(64), deletedAt = now - day)
        assertEquals(listOf(newer, older), DeletedPostsStore.unexpired(listOf(older, newer), now))
    }

    // ── Un-delete event ─────────────────────────────────────────

    /**
     * Un-delete signs the same kind, text and tags, so a deleted reply comes
     * back in its thread, and the event it signs is stamped now, not with the
     * old post's time. Built through the same builder the local signer uses.
     */
    @Test
    fun `un-delete builds the same kind content and tags with a new created_at`() {
        val saved = post()
        val draft = saved.republishDraft()
        assertEquals(saved.kind, draft.kind)
        assertEquals(saved.content, draft.content)
        assertEquals(saved.tags, draft.tags)

        val before = System.currentTimeMillis() / 1000
        val unsigned = Json.parseToJsonElement(
            EventPublisher.buildUnsignedEvent(pubkey = me, kind = draft.kind, content = draft.content, tags = draft.tags)
        ).jsonObject
        val createdAt = unsigned["created_at"]!!.jsonPrimitive.long
        assertTrue("created_at $createdAt should be now, not ${saved.createdAt}", createdAt >= before)
        assertEquals(saved.content, unsigned["content"]!!.jsonPrimitive.content)
        assertEquals(saved.tags.size, unsigned["tags"]!!.jsonArray.size)
    }

    @Test
    fun `un-delete drops the old proof of work`() {
        val saved = post(tags = listOf(listOf("p", other), listOf("nonce", "12345", "20")))
        assertEquals(listOf(listOf("p", other)), saved.republishDraft().tags)
    }
}
