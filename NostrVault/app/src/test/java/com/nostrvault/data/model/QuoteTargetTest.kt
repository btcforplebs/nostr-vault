package com.nostrvault.data.model

import kotlinx.serialization.json.buildJsonArray
import kotlinx.serialization.json.buildJsonObject
import kotlinx.serialization.json.put
import org.junit.Assert.assertEquals
import org.junit.Assert.assertSame
import org.junit.Test

/**
 * Quoting a kind-6 repost cites the original note's id and author — never the
 * reposter. Mirrors iOS `FeedService.quoteTarget(for:)` (#66, #67).
 */
class QuoteTargetTest {
    private val original = "a".repeat(64)
    private val repost = "b".repeat(64)
    private val author = "c".repeat(64)
    private val reposter = "d".repeat(64)

    private fun repostNote(content: String) = FeedNote.fromEvent(
        id = repost,
        pubkey = reposter,
        content = content,
        tags = listOf(listOf("e", original, "wss://relay.example"), listOf("p", author)),
        createdAt = 1_700_000_000,
        kind = 6,
    )

    private fun embedded(withTags: Boolean = true) = buildJsonObject {
        put("id", original)
        put("pubkey", author)
        put("kind", 1)
        put("created_at", 1_699_999_000)
        put("content", "the original post")
        if (withTags) put("tags", buildJsonArray { })
        put("sig", "0".repeat(128))
    }.toString()

    private fun target(note: FeedNote, loaded: FeedNote? = null) =
        FeedNote.quoteTarget(note) { id -> loaded?.takeIf { it.id == id } }

    @Test fun bareRepostCitesOriginalAuthorFromPTag() {
        val t = target(repostNote(""))
        assertEquals(original, t.id)
        assertEquals(author, t.pubkey)
        assertEquals("", t.content)
    }

    @Test fun repostWhoseContentIsNotACopyStillCitesOriginalAuthor() {
        // Not JSON: nothing was unpacked, so the note still carries the reposter.
        val t = target(repostNote("look at this"))
        assertEquals(original, t.id)
        assertEquals(author, t.pubkey)
    }

    @Test fun embeddedRepostIsRebuiltFromItsCopy() {
        val t = target(repostNote(embedded()))
        assertEquals(original, t.id)
        assertEquals(author, t.pubkey)
        assertEquals("the original post", t.content)
        assertEquals(1, t.kind)
    }

    @Test fun embeddedCopyWithoutTagsIsStillUnpacked() {
        // The copy's tags replace the repost's even when it has none; keeping
        // the repost's `e` tag would make it look bare and drop the body.
        val t = target(repostNote(embedded(withTags = false)))
        assertEquals(author, t.pubkey)
        assertEquals("the original post", t.content)
    }

    @Test fun loadedOriginalWins() {
        val loaded = FeedNote.fromEvent(
            id = original, pubkey = author, content = "loaded", tags = emptyList(),
            createdAt = 1_699_999_000, kind = 1,
        )
        assertSame(loaded, target(repostNote(""), loaded))
    }

    @Test fun anotherRepostOfTheSameNoteIsNotTheOriginal() {
        val otherRepost = FeedNote.fromEvent(
            id = original, pubkey = reposter, content = "", tags = emptyList(),
            createdAt = 1_699_999_000, kind = 6,
        )
        assertEquals(author, target(repostNote(""), otherRepost).pubkey)
    }

    @Test fun plainNoteIsItsOwnTarget() {
        val note = FeedNote.fromEvent(
            id = original, pubkey = author, content = "hi", tags = emptyList(),
            createdAt = 1_699_999_000, kind = 1,
        )
        assertSame(note, target(note))
    }

    // effectiveAuthor / effectiveKind / publisher: who a zap, report or block
    // on a repost reaches, and who may delete it.

    @Test fun bareRepostEngagesOriginalAuthor() {
        val n = repostNote("")
        assertEquals(author, n.effectiveAuthor)
        assertEquals(original, n.effectiveEventId)
        assertEquals(1, n.effectiveKind)
        assertEquals(reposter, n.publisher)
    }

    @Test fun repostWhoseContentIsNotACopyEngagesOriginalAuthor() {
        val n = repostNote("look at this")
        assertEquals(author, n.effectiveAuthor)
        assertEquals(reposter, n.publisher)
    }

    @Test fun embeddedRepostEngagesOriginalAuthor() {
        val n = repostNote(embedded())
        assertEquals(author, n.effectiveAuthor)
        assertEquals(1, n.effectiveKind)
        assertEquals(reposter, n.publisher)
    }

    @Test fun ordinaryNoteEngagesItsOwnAuthor() {
        val n = FeedNote.fromEvent(id = original, pubkey = author, content = "hi",
            tags = listOf(listOf("p", reposter)), createdAt = 1_700_000_000, kind = 1)
        assertEquals(author, n.effectiveAuthor)
        assertEquals(author, n.publisher)
        assertEquals(1, n.effectiveKind)
    }
}
