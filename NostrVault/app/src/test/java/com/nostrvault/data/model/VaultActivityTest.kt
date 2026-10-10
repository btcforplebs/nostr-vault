package com.nostrvault.data.model

import kotlinx.serialization.json.JsonArray
import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.JsonPrimitive
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test
import java.time.ZoneOffset

/** The Vault tab's "Vault" list: what others did that reached you. Mirrors iOS VaultActivityTests (#506). */
class VaultActivityTest {
    private val me = "a".repeat(64)
    private val ann = "b".repeat(64)
    private val bob = "c".repeat(64)
    private val cat = "d".repeat(64)
    private val noteKinds = setOf(1, 6, 30023, 1111, 9802, 1068)

    private fun event(
        id: String, pubkey: String, kind: Int = 1, at: Long,
        content: String = "", tags: List<List<String>> = emptyList(),
    ) = VaultActivity.Event(id, pubkey, kind, at, content, tags)

    private fun zapReceipt(
        id: String, from: String, on: String?, sats: Long, at: Long, comment: String = "",
    ): VaultActivity.Event {
        val requestTags = buildList {
            add(listOf("p", me))
            add(listOf("amount", "${sats * 1000}"))
            if (on != null) add(listOf("e", on))
        }
        val request = JsonObject(
            mapOf(
                "pubkey" to JsonPrimitive(from),
                "content" to JsonPrimitive(comment),
                "kind" to JsonPrimitive(9734),
                "tags" to JsonArray(requestTags.map { tag -> JsonArray(tag.map { JsonPrimitive(it) }) }),
            ),
        )
        val tags = buildList {
            add(listOf("p", me))
            add(listOf("description", request.toString()))
            if (on != null) add(listOf("e", on))
        }
        return event(id, "lnurlprovider", kind = 9735, at = at, tags = tags)
    }

    private fun build(
        events: List<VaultActivity.Event>,
        follows: List<VaultActivity.Follow> = emptyList(),
        isBlocked: (String) -> Boolean = { false },
        isOutside: (String) -> Boolean = { false },
    ) = VaultActivity.build(events, me, noteKinds, follows, isBlocked, isOutside, zone = ZoneOffset.UTC)

    @Test fun `likes on one post fold into one line, newest actor first`() {
        val lines = build(
            listOf(
                event("post", me, at = 100, content = "my   post\ntext"),
                event("r1", ann, kind = 7, at = 110, content = "+", tags = listOf(listOf("e", "post"), listOf("p", me))),
                event("r2", bob, kind = 7, at = 130, content = "🔥", tags = listOf(listOf("e", "post"), listOf("p", me))),
                event("r3", ann, kind = 7, at = 120, content = "+", tags = listOf(listOf("e", "post"), listOf("p", me))),
            ),
        )
        assertEquals(1, lines.size)
        val line = lines[0]
        assertEquals(VaultActivity.Kind.REACTION, line.kind)
        assertEquals(listOf(bob, ann), line.actors)
        assertEquals(130L, line.createdAt)
        assertEquals("post", line.openId)
        assertEquals("my post text", line.preview)
        assertEquals(listOf("🔥", "+"), line.emojis)
        assertTrue(line.aboutYourPost)
    }

    @Test fun `reactions to someone else's post are not yours`() {
        val lines = build(
            listOf(
                event("theirs", ann, at = 100),
                event("r1", bob, kind = 7, at = 110, tags = listOf(listOf("e", "theirs"), listOf("p", ann))),
            ),
        )
        assertTrue(lines.isEmpty())
    }

    @Test fun `replies, mentions and quotes each get a line, newest first`() {
        val lines = build(
            listOf(
                event("post", me, at = 100, content = "hello"),
                event("reply", ann, at = 110, content = "hi back", tags = listOf(listOf("e", "post"), listOf("p", me))),
                event("mention", bob, at = 120, content = "cc nostr:npub", tags = listOf(listOf("p", me))),
                event("quote", cat, at = 130, content = "look", tags = listOf(listOf("q", "post"), listOf("p", me))),
            ),
        )
        assertEquals(
            listOf(VaultActivity.Kind.QUOTE, VaultActivity.Kind.MENTION, VaultActivity.Kind.REPLY),
            lines.map { it.kind },
        )
        assertEquals(listOf("quote", "mention", "reply"), lines.map { it.openId })
        assertEquals("hi back", lines.last().preview)
        assertTrue(lines.none { it.aboutYourPost })
    }

    @Test fun `own events, blocked and outside authors are left out`() {
        val lines = build(
            listOf(
                event("post", me, at = 100),
                event("self", me, at = 105, tags = listOf(listOf("p", me))),
                event("blocked", bob, at = 110, tags = listOf(listOf("p", me))),
                event("blockedLike", bob, kind = 7, at = 111, tags = listOf(listOf("e", "post"))),
                event("spam", cat, at = 120, tags = listOf(listOf("p", me))),
                // Outside your network only hides posts that tag you, as in Notes.
                event("like", cat, kind = 7, at = 130, tags = listOf(listOf("e", "post"))),
            ),
            isBlocked = { it == bob },
            isOutside = { it == cat },
        )
        assertEquals(listOf("reaction-post"), lines.map { it.id })
    }

    @Test fun `zaps fold per post and sum, while comments and profile zaps stand alone`() {
        val lines = build(
            listOf(
                event("post", me, at = 100, content = "zap me"),
                zapReceipt("z1", from = ann, on = "post", sats = 21, at = 110),
                zapReceipt("z2", from = bob, on = "post", sats = 1000, at = 120),
                zapReceipt("z3", from = cat, on = "post", sats = 5, at = 130, comment = "great post"),
                zapReceipt("z4", from = ann, on = null, sats = 100, at = 140),
                zapReceipt("mine", from = me, on = "post", sats = 9, at = 150),
            ),
        )
        assertEquals(listOf("z4", "z3", "zap-post"), lines.map { it.id })
        assertNull(lines[0].openId)
        assertEquals(100L, lines[0].sats)
        assertEquals("great post", lines[1].preview)
        assertEquals("post", lines[1].openId)
        assertEquals(listOf(bob, ann), lines[2].actors)
        assertEquals(1021L, lines[2].sats)
        assertEquals("zap me", lines[2].preview)
        // Only the folded line quotes your post; a comment is their words.
        assertEquals(listOf(false, false, true), lines.map { it.aboutYourPost })
    }

    @Test fun `reposts of your post fold`() {
        val lines = build(
            listOf(
                event("post", me, at = 100, content = "share this"),
                event("rp1", ann, kind = 6, at = 110, tags = listOf(listOf("e", "post"), listOf("p", me))),
                event("rp2", bob, kind = 6, at = 120, tags = listOf(listOf("e", "post"), listOf("p", me))),
            ),
        )
        assertEquals(1, lines.size)
        assertEquals(VaultActivity.Kind.REPOST, lines[0].kind)
        assertEquals(listOf(bob, ann), lines[0].actors)
    }

    @Test fun `articles and highlights that tag you`() {
        val lines = build(
            listOf(
                event("art", ann, kind = 30023, at = 110, content = "long body", tags = listOf(listOf("title", "My Essay"), listOf("p", me))),
                event("hl", bob, kind = 9802, at = 120, content = "a quoted line", tags = listOf(listOf("p", me))),
            ),
        )
        assertEquals(listOf(VaultActivity.Kind.HIGHLIGHT, VaultActivity.Kind.ARTICLE), lines.map { it.kind })
        assertEquals("My Essay", lines[1].preview)
    }

    @Test fun `follows on one day fold and interleave by time`() {
        val day1 = 1_790_000_000L
        val lines = build(
            listOf(event("mention", cat, at = day1 + 50, tags = listOf(listOf("p", me)))),
            follows = listOf(
                VaultActivity.Follow(ann, day1),
                VaultActivity.Follow(bob, day1 + 100),
                VaultActivity.Follow(cat, day1 + 3 * 86_400),
            ),
        )
        assertEquals(
            listOf(VaultActivity.Kind.FOLLOW, VaultActivity.Kind.FOLLOW, VaultActivity.Kind.MENTION),
            lines.map { it.kind },
        )
        assertEquals(listOf(cat), lines[0].actors)
        assertEquals(listOf(bob, ann), lines[1].actors)
        assertEquals(day1 + 100, lines[1].createdAt)
        assertNull(lines[1].openId)
    }

    @Test fun `no owner, no lines`() {
        val lines = VaultActivity.build(
            listOf(event("x", ann, at = 1, tags = listOf(listOf("p", "")))),
            owner = "",
            noteKinds = noteKinds,
        )
        assertTrue(lines.isEmpty())
    }

    @Test fun `who names one, two, or the first and a count`() {
        val name: (String) -> String = { it.take(1) }
        assertEquals("Someone", VaultActivity.who(emptyList(), name))
        assertEquals("b", VaultActivity.who(listOf(ann), name))
        assertEquals("b and c", VaultActivity.who(listOf(ann, bob), name))
        assertEquals("b and 3 others", VaultActivity.who(listOf(ann, bob, cat, me), name))
    }
}
