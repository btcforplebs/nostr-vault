package com.nostrvault.service

import com.nostrvault.data.model.NIP10Thread
import kotlinx.serialization.json.Json
import kotlinx.serialization.json.JsonArray
import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.jsonArray
import kotlinx.serialization.json.jsonPrimitive
import kotlinx.serialization.json.long
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

/** The live replies subscription a thread keeps open (iOS NoteDetailView's replies REQ past EOSE). */
class LiveThreadRepliesTest {
    private val root = "a".repeat(64)
    private val focus = "b".repeat(64)
    private val author = "c".repeat(64)

    private fun kindsOf(f: JsonObject) = (f["kinds"] as JsonArray).map { it.jsonPrimitive.content.toInt() }
    private fun tagOf(f: JsonObject, tag: String) = (f[tag] as? JsonArray)?.map { it.jsonPrimitive.content }

    @Test fun theFiltersAskForNotesAndCommentsOnTheRootAndFocusFromSince() {
        val filters = LiveThreadReplies.filters(root, focus, rootCoordinate = null, since = 1_000)
        assertEquals(2, filters.size)
        assertEquals(listOf(1, NIP10Thread.COMMENT_KIND), kindsOf(filters[0]))
        assertEquals(listOf(root, focus), tagOf(filters[0], "#e"))
        assertEquals(listOf(NIP10Thread.COMMENT_KIND), kindsOf(filters[1]))
        assertEquals(listOf(root), tagOf(filters[1], "#E"))
        assertTrue(filters.all { it["since"]!!.jsonPrimitive.long == 1_000L })
        // Nothing older than since, and no limit: it streams, it doesn't page.
        assertTrue(filters.none { it.containsKey("limit") })
    }

    @Test fun anAddressableRootAlsoGetsItsCommentsByAddress() {
        val coordinate = "30023:$author:post"
        val filters = LiveThreadReplies.filters(root, root, coordinate, since = 1)
        assertEquals(3, filters.size)
        assertEquals(listOf(coordinate), tagOf(filters[2], "#A"))
        // The root opened as itself is asked for once.
        assertEquals(listOf(root), tagOf(filters[0], "#e"))
    }

    @Test fun theRequestCarriesTheSubIdAndEveryFilter() {
        val filters = LiveThreadReplies.filters(root, focus, null, 5)
        val req = Json.parseToJsonElement(LiveThreadReplies.request("live-replies-x", filters)).jsonArray
        assertEquals("REQ", req[0].jsonPrimitive.content)
        assertEquals("live-replies-x", req[1].jsonPrimitive.content)
        assertEquals(filters, req.drop(2))
    }

    private fun event(kind: Int, content: String = "nice point", id: String = "d".repeat(64)) =
        """{"id":"$id","pubkey":"$author","kind":$kind,"created_at":1700000000,"content":"$content","tags":[["e","$root","","root"]],"sig":"00"}"""

    @Test fun aReplyUnderTheSubIdIsTakenWithItsRawJson() {
        val (note, raw) = LiveThreadReplies.replyOf("""["EVENT","sub-1",${event(1)}]""", "sub-1")!!
        assertEquals("d".repeat(64), note.id)
        assertEquals(author, note.pubkey)
        assertEquals(root, note.tags.first()[1])
        assertTrue(raw.contains("\"sig\":\"00\""))
        assertNotNull(LiveThreadReplies.replyOf("""["EVENT","sub-1",${event(NIP10Thread.COMMENT_KIND)}]""", "sub-1"))
    }

    @Test fun anythingElseIsLeftOut() {
        // Another subscription on the socket, an EOSE, a reaction, garbage.
        assertNull(LiveThreadReplies.replyOf("""["EVENT","sub-2",${event(1)}]""", "sub-1"))
        assertNull(LiveThreadReplies.replyOf("""["EOSE","sub-1"]""", "sub-1"))
        assertNull(LiveThreadReplies.replyOf("""["EVENT","sub-1",${event(7, "+")}]""", "sub-1"))
        assertNull(LiveThreadReplies.replyOf("not json", "sub-1"))
        assertNull(LiveThreadReplies.replyOf("""["EVENT","sub-1",{"kind":1}]""", "sub-1"))
    }
}
