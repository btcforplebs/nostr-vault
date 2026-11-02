package com.nostrvault.service

import org.junit.Assert.assertEquals
import org.junit.Test

/** Kind 10003 bookmarks: one tap changes one entry (iOS twin: `BookmarkListTests.swift`). */
class BookmarkListTest {
    private val id = "a".repeat(64)
    private val pk = "b".repeat(64)

    @Test
    fun aNoteIsAnEventAndAnArticleAnAddress() {
        assertEquals(BookmarkList.Entry.Event(id), BookmarkList.entry(id.uppercase(), pk, 1, emptyList()))
        assertEquals(
            BookmarkList.Entry.Address("30023:$pk:my-post"),
            BookmarkList.entry(id, pk.uppercase(), 30023, listOf(listOf("d", "my-post"))),
        )
        assertEquals("a d may hold colons", "a:b", BookmarkList.Entry.Address("30023:$pk:a:b").parts?.third)
    }

    @Test
    fun addKeepsEveryOtherTagAndAppendsOnce() {
        val base = listOf(listOf("t", "nostr"), listOf("e", "old"), listOf("r", "https://x"), listOf("unknown", "1", "2"))
        val added = BookmarkList.toggled(base, BookmarkList.Entry.Event(id), on = true)
        assertEquals(base + listOf(listOf("e", id)), added)
        assertEquals("already there: unchanged", added, BookmarkList.toggled(added, BookmarkList.Entry.Event(id), on = true))
    }

    @Test
    fun removeTakesOutEveryCopyOnlyOfThatEntry() {
        val base = listOf(
            listOf("e", id, "wss://hint"), listOf("t", "x"), listOf("e", id.uppercase()), listOf("e", "other"),
            listOf("a", "30023:$pk:d"),
        )
        assertEquals(
            listOf(listOf("t", "x"), listOf("e", "other"), listOf("a", "30023:$pk:d")),
            BookmarkList.toggled(base, BookmarkList.Entry.Event(id), on = false),
        )
        assertEquals(4, BookmarkList.toggled(base, BookmarkList.Entry.Address("30023:$pk:d"), on = false).size)
        assertEquals(base, BookmarkList.toggled(base, BookmarkList.Entry.Event("missing"), on = false))
    }

    @Test
    fun entriesNewestFirstOnceIgnoringOtherTags() {
        val tags = listOf(
            listOf("e", "one"), listOf("t", "x"), listOf("a", "30023:$pk:d"), listOf("e", "two"), listOf("e", "ONE"), listOf("e", ""),
        )
        assertEquals(
            listOf(BookmarkList.Entry.Event("one"), BookmarkList.Entry.Event("two"), BookmarkList.Entry.Address("30023:$pk:d")),
            BookmarkList.entries(tags),
        )
    }

    @Test
    fun privateEntriesFromDecryptedContent() {
        assertEquals(
            listOf(BookmarkList.Entry.Address("30023:$pk:d"), BookmarkList.Entry.Event(id)),
            BookmarkList.privateEntries("""[["e","$id"],["t","x"],["a","30023:$pk:d"]]"""),
        )
        assertEquals(emptyList<BookmarkList.Entry>(), BookmarkList.privateEntries("not json"))
    }
}
