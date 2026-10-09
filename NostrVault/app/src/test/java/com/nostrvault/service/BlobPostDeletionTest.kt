package com.nostrvault.service

import org.junit.Assert.assertEquals
import org.junit.Test

class BlobPostDeletionTest {
    private val me = "a".repeat(64)
    private val other = "b".repeat(64)
    private val hash = "0123456789abcdef".repeat(4)

    private fun event(
        id: String,
        kind: Int = 1,
        pubkey: String = me,
        content: String = "",
        tags: List<List<String>> = emptyList(),
    ) = NostrEvent(id = id, pubkey = pubkey, createdAt = 0, kind = kind, tags = tags, content = content, sig = "")

    @Test
    fun `finds your posts that link the hash in text or tags, any case`() {
        val events = listOf(
            event("text", content = "look https://blossom.band/$hash.jpg"),
            event("imeta", kind = 20, tags = listOf(listOf("imeta", "url https://x/${hash.uppercase()}.png", "x $hash"))),
            event("unrelated", content = "no media here"),
        )
        assertEquals(listOf("text", "imeta"), BlobPostDeletion.referencing(events, me, hash.uppercase()).map { it.id })
    }

    @Test
    fun `never someone else's post, a profile, a list or a DM`() {
        val events = listOf(
            event("theirs", pubkey = other, content = hash),
            event("profile", kind = 0, content = """{"picture":"https://x/$hash"}"""),
            event("list", kind = 10063, tags = listOf(listOf("x", hash))),
            event("dm", kind = 14, content = hash),
            event("article", kind = 30023, content = hash),
        )
        assertEquals(emptyList<NostrEvent>(), BlobPostDeletion.referencing(events, me, hash))
    }

    @Test
    fun `all post kinds count`() {
        val events = BlobPostDeletion.POST_KINDS.map { event("k$it", kind = it, content = hash) }
        assertEquals(6, BlobPostDeletion.referencing(events, me, hash).size)
    }

    @Test
    fun `no owner or a malformed hash matches nothing`() {
        val events = listOf(event("p", content = hash))
        assertEquals(0, BlobPostDeletion.referencing(events, "", hash).size)
        assertEquals(0, BlobPostDeletion.referencing(events, me, hash.take(16)).size)
    }

    @Test
    fun `one request names every post and each kind once, sorted`() {
        val targets = listOf(event("e1", kind = 20), event("e2", kind = 1), event("e3", kind = 20))
        assertEquals(
            listOf(listOf("e", "e1"), listOf("e", "e2"), listOf("e", "e3"), listOf("k", "1"), listOf("k", "20")),
            BlobPostDeletion.deletionTags(targets),
        )
    }
}
