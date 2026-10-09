package com.nostrvault.data.model

import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Test

class DraftEventsTest {
    private val me = "a".repeat(64)

    /** iOS DraftService writes NIP-10 markers and a 4-element `q`. */
    @Test fun readsTheIosShape() {
        val d = DraftEvents.fromEvent(
            content = "hello",
            pubkey = me,
            tags = listOf(
                listOf("d", "draft-1"), listOf("k", "1"),
                listOf("e", "root1", "wss://x", "root"), listOf("e", "parent1", "wss://x", "reply"),
                listOf("p", "b".repeat(64)), listOf("q", "quoted1", "wss://y", "c".repeat(64)),
            ),
            createdAt = 1_700_000_000,
        )!!
        assertEquals("draft-1", d.id)
        assertEquals("parent1", d.replyToId)
        assertEquals("root1", d.rootId)
        assertEquals("quoted1", d.quoteId)
        assertEquals("c".repeat(64), d.quotePubkey)
        assertEquals(me, d.pubkey)
        assertEquals(1_700_000_000_000, d.updatedAt)
    }

    /** Drafts this app published before used its own tag names. */
    @Test fun readsTheOldAndroidShape() {
        val d = DraftEvents.fromEvent(
            "x", me,
            listOf(listOf("d", "old"), listOf("reply", "p1"), listOf("root", "r1"), listOf("q", "q1"), listOf("qp", "qpk")),
            1,
        )!!
        assertEquals("p1", d.replyToId)
        assertEquals("r1", d.rootId)
        assertEquals("q1", d.quoteId)
        assertEquals("qpk", d.quotePubkey)
    }

    @Test fun noDTagIsNotADraft() {
        assertNull(DraftEvents.fromEvent("x", me, listOf(listOf("k", "1")), 1))
        assertNull(DraftEvents.fromEvent("x", me, listOf(listOf("d", "")), 1))
    }

    /** What we write comes back the same, so iOS reads Android's drafts. */
    @Test fun tagsRoundTrip() {
        val reply = Draft(id = "r", content = "c", pubkey = me, replyToId = "p1", rootId = "root1",
            quoteId = "q1", quotePubkey = "qpk")
        val back = DraftEvents.fromEvent("c", me, DraftEvents.tags(reply), 5)!!
        assertEquals(listOf("p1", "root1", "q1", "qpk"), listOf(back.replyToId, back.rootId, back.quoteId, back.quotePubkey))

        // A reply to a root note: the parent is both root and reply, as on iOS.
        val top = DraftEvents.fromEvent("c", me, DraftEvents.tags(Draft(id = "t", content = "c", replyToId = "p2")), 5)!!
        assertEquals("p2", top.rootId)
        assertEquals("p2", top.replyToId)

        val plain = DraftEvents.tags(Draft(id = "n", content = "c"))
        assertEquals(listOf(listOf("d", "n"), listOf("k", "1")), plain)
    }

    @Test fun mergeKeepsNewerAndLocalOnly() {
        val localOld = Draft(id = "1", content = "old", updatedAt = 1_000)
        val localOnly = Draft(id = "2", content = "mine", updatedAt = 5_000)
        val localNewer = Draft(id = "3", content = "phone", updatedAt = 9_000)
        val relayNew = Draft(id = "1", content = "new", updatedAt = 2_000)
        val relayOlder = Draft(id = "3", content = "mac", updatedAt = 8_000)
        val relayOnly = Draft(id = "4", content = "ipad", updatedAt = 3_000)

        val merged = DraftEvents.merge(listOf(localOld, localOnly, localNewer), listOf(relayNew, relayOlder, relayOnly))
        assertEquals(listOf("3", "2", "4", "1"), merged.map { it.id })
        assertEquals("new", merged.first { it.id == "1" }.content)
        assertEquals("phone", merged.first { it.id == "3" }.content)
    }

    /** A tie goes to the relay copy, as on iOS. */
    @Test fun mergeTieGoesToRelay() {
        val merged = DraftEvents.merge(listOf(Draft(id = "1", content = "local", updatedAt = 7)),
            listOf(Draft(id = "1", content = "relay", updatedAt = 7)))
        assertEquals("relay", merged.single().content)
    }

    /** A draft deleted here stays gone even though the relay still returns it. */
    @Test fun mergeSkipsDeleted() {
        val merged = DraftEvents.merge(
            listOf(Draft(id = "keep", content = "", updatedAt = 1)),
            listOf(Draft(id = "gone", content = "", updatedAt = 9), Draft(id = "new", content = "", updatedAt = 5)),
            deleted = setOf("gone"),
        )
        assertEquals(listOf("new", "keep"), merged.map { it.id })
    }

    @Test fun coordinateRoundTrip() {
        val c = DraftEvents.coordinate(me, "abc:def")
        assertEquals("31234:$me:abc:def", c)
        assertEquals("abc:def", DraftEvents.idOf(c))
    }

    @Test fun forAccountKeepsOwnAndUnowned() {
        val drafts = listOf(Draft(id = "a", content = "", pubkey = me), Draft(id = "b", content = "", pubkey = "other"),
            Draft(id = "c", content = ""))
        assertEquals(listOf("a", "c"), DraftEvents.forAccount(drafts, me).map { it.id })
    }
}
