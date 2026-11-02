package com.nostrvault.service

import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

/**
 * The vault's list history as the app reads it (iOS twin: `ListHistoryTests.swift`;
 * the shrink table matches haven-go `list_shrink_test.go` case for case).
 */
class ListHistoryTest {
    private var serial = 0

    private fun list(
        kind: Int, items: Int, content: String = "", at: Long = 0, first: Int = 0,
        extra: List<List<String>> = emptyList(), author: String = "me",
    ): ListVersion {
        serial++
        val tags = extra + (first until first + items).map { listOf("e", "item$it") }
        return ListVersion("id$serial", author, kind, at, tags, content)
    }

    private fun profile(content: String, at: Long = 0): ListVersion {
        serial++
        return ListVersion("p$serial", "me", 0, at, emptyList(), content)
    }

    @Test
    fun shrinkRuleTable() {
        val big = "x".repeat(2000)
        val cases = listOf(
            Triple("emptied", list(10003, 3) to list(10003, 0), true),
            Triple("emptied a one-item list", list(10002, 1) to list(10002, 0), true),
            Triple("fewer than half of 240", list(10003, 240) to list(10003, 100), true),
            Triple("exactly half is an edit", list(10003, 20) to list(10003, 10), false),
            Triple("small list edited down", list(10002, 4) to list(10002, 1), false),
            Triple("nine to one is small", list(3, 9) to list(3, 1), false),
            Triple("ten to four", list(3, 10) to list(3, 4), true),
            Triple("a grow", list(3, 10) to list(3, 30), false),
            Triple("empty to empty", list(3, 0) to list(3, 0), false),
            Triple("private part wiped", list(10000, 2, big) to list(10000, 2), true),
            Triple("private part cut by more than half", list(10003, 2, big) to list(10003, 2, big.take(900)), true),
            Triple("private part edited", list(10003, 2, big) to list(10003, 2, big.take(1200)), false),
            Triple("small private part shortened", list(10003, 2, big.take(400)) to list(10003, 2, big.take(100)), false),
            Triple("kind 3 content is not a private part", list(3, 5, big) to list(3, 5), false),
            Triple("profile emptied", profile("""{"name":"a","about":"b","picture":"c"}""") to profile("{}"), true),
            Triple("profile fields blanked", profile("""{"name":"a","about":"b"}""") to profile("""{"name":"","about":""}"""), true),
            Triple("profile edited", profile("""{"name":"a","about":"b"}""") to profile("""{"name":"z"}"""), false),
            Triple(
                "title and d are not items",
                list(30003, 0, extra = listOf(listOf("d", "x"), listOf("title", "T"))) to list(30003, 0, extra = listOf(listOf("d", "x"))),
                false,
            ),
        )
        for ((name, pair, want) in cases) {
            assertEquals(name, want, ListShrinkRule.shrank(pair.first, pair.second))
        }
    }

    @Test
    fun kindSetMatchesTheVault() {
        assertEquals(
            listOf(0, 3, 10000, 10001, 10002, 10003, 10004, 10006, 10007, 10015, 10030, 10050, 10063, 30000, 30002, 30003),
            ListShrinkRule.protectedKinds,
        )
        assertFalse(ListShrinkRule.isProtected(1))
        assertFalse(ListShrinkRule.isProtected(30023))
    }

    @Test
    fun profileFieldCount() {
        assertEquals(3, ListShrinkRule.itemCount(profile("""{"name":"a","about":"","picture":"p","bot":false,"x":null}""")))
        assertEquals(0, ListShrinkRule.itemCount(profile("not json")))
    }

    @Test
    fun holdsNeedsEveryItemNotTheSameCount() {
        val old = list(10003, 15)
        assertFalse(ListShrinkRule.holds(list(10003, 15, first = 100), old))
        assertTrue(ListShrinkRule.holds(list(10003, 16), old))
    }

    @Test
    fun groupsPerListNewestFirstOwnAuthorOnly() {
        val a1 = list(30003, 1, at = 1, extra = listOf(listOf("d", "reading")))
        val a2 = list(30003, 2, at = 2, extra = listOf(listOf("d", "reading")))
        val b = list(30003, 1, at = 1, extra = listOf(listOf("d", "recipes")))
        val stranger = list(10003, 3, at = 5, author = "them")
        val note = list(1, 0, at = 5)
        val groups = ListHistory.group(listOf(a1, b, a2, a2, stranger, note), "me")
        assertEquals(listOf(a2.id, a1.id), groups[ListHistory.Key(30003, "reading")]?.map { it.id })
        assertEquals(listOf(b.id), groups[ListHistory.Key(30003, "recipes")]?.map { it.id })
        assertEquals(2, groups.size)
    }

    @Test
    fun latestWipeOffersTheVersionBefore() {
        val full = list(10003, 24, at = 1)
        val wiped = list(10003, 0, at = 2)
        assertEquals(ListHistory.Wipe(full, wiped), ListHistory.latestWipe(listOf(wiped, full)))
        assertNull("an edit is no wipe", ListHistory.latestWipe(listOf(list(10003, 23, at = 3), full)))
        assertNull("a wipe that is no longer newest", ListHistory.latestWipe(listOf(list(10003, 1, at = 3), wiped, full)))
    }

    @Test
    fun latestWipeOffersTheLargestSinceTheWipeBefore() {
        val full = list(10003, 20, at = 1)
        val late = list(10003, 11, at = 2)
        val wiped = list(10003, 0, at = 3)
        assertEquals(full, ListHistory.latestWipe(listOf(wiped, late, full))?.before)
        val older = list(10003, 40, at = 0)
        val oldWipe = list(10003, 0, at = 1)
        val rebuilt = list(10003, 12, at = 2)
        val again = list(10003, 0, at = 3)
        assertEquals("never across an older wipe", rebuilt, ListHistory.latestWipe(listOf(again, rebuilt, oldWipe, older))?.before)
    }

    @Test
    fun diffAndRestoredList() {
        val old = list(3, 3, "old relays")
        val current = list(3, 2, "current relays", first = 2)
        val (comeBack, go) = ListHistory.diff(old, current)
        assertEquals(setOf("e\u0000item0", "e\u0000item1"), comeBack)
        assertEquals(setOf("e\u0000item3"), go)
        val (tags, content) = ListHistory.restored(old, current)
        assertEquals(old.tags, tags)
        assertEquals("kind 3 keeps the current content", "current relays", content)
        assertEquals("ciphertext", ListHistory.restored(list(10000, 2, "ciphertext"), list(10000, 0)).second)
    }
}
