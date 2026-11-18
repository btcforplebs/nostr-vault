package com.nostrvault.data.model

import org.junit.Assert.assertEquals
import org.junit.Assert.assertNotSame
import org.junit.Assert.assertSame
import org.junit.Test
import java.util.Date
import kotlin.random.Random

/** Building with a [FeedThreadMemo] must give exactly what a fresh build gives (perf review 2026-11-18, item 2). */
class FeedThreadMemoTest {

    private fun note(id: String, seconds: Long, parent: String? = null, root: String? = null, author: String = "alice") = FeedNote(
        id = id,
        pubkey = author,
        content = "",
        createdAt = Date(seconds * 1000),
        tags = buildList {
            if (root != null) add(listOf("e", root, "", "root"))
            if (parent != null && parent != root) add(listOf("e", parent, "", "reply"))
        },
        kind = 1,
        repostedBy = null,
        isReply = parent != null,
        replyToPubkey = null,
        parentEventId = parent,
        mediaURLs = emptyList(),
        linkURLs = emptyList(),
        quotedEventIds = emptyList(),
        repostedEventId = null,
    )

    /** A random feed that grows, loses notes and fetches ancestors, built with and without the memo at each step. */
    @Test
    fun `a memo build equals a fresh build at every step`() {
        repeat(40) { seed ->
            val rnd = Random(seed)
            val all = ArrayList<FeedNote>()
            for (i in 0 until 120) {
                val replyTo = if (all.isNotEmpty() && rnd.nextInt(3) > 0) all[rnd.nextInt(all.size)] else null
                val root = replyTo?.let { it.tags.firstOrNull { t -> t.getOrNull(3) == "root" }?.get(1) ?: it.id }
                // Ties on purpose: the order among equal timestamps must hold too.
                all += note("n$i", 1000L + rnd.nextInt(60), parent = replyTo?.id, root = root, author = "a${rnd.nextInt(5)}")
            }
            val memo = FeedThreadMemo()
            val fetched = HashMap<String, FeedNote>()
            var feed = all.take(30)
            for (step in 0 until 25) {
                when (rnd.nextInt(4)) {
                    0 -> feed = (feed + all.filter { it !in feed }.shuffled(rnd).take(rnd.nextInt(1, 8)))
                    1 -> if (feed.size > 5) feed = feed.filterIndexed { i, _ -> i != rnd.nextInt(feed.size) }
                    2 -> all.shuffled(rnd).take(3).forEach { fetched[it.id] = it }
                    else -> feed = feed.shuffled(rnd)
                }
                val sorted = feed.sortedByDescending { it.createdAt }
                for (keep in listOf(false, true)) {
                    val fresh = FeedThreadGrouping.build(sorted, keepFeedOrder = keep) { fetched[it] }
                    val memoed = FeedThreadGrouping.build(sorted, keepFeedOrder = keep, memo = memo) { fetched[it] }
                    assertEquals("seed $seed step $step keep $keep", fresh, memoed)
                }
            }
        }
    }

    @Test
    fun `an untouched thread is handed back as the same instance, a touched one is rebuilt`() {
        val a = note("a", 100)
        val b = note("b", 200)
        val memo = FeedThreadMemo()
        val first = FeedThreadGrouping.build(listOf(b, a), memo = memo)
        val reply = note("r", 300, parent = "a", root = "a", author = "bob")
        val second = FeedThreadGrouping.build(listOf(reply, b, a), memo = memo)
        assertEquals(listOf("a", "b"), second.map { it.rootId })
        assertSame(first.first { it.rootId == "b" }, second.first { it.rootId == "b" })
        assertNotSame(first.first { it.rootId == "a" }, second.first { it.rootId == "a" })
        assertEquals(listOf("a", "r"), second.first { it.rootId == "a" }.entries.map { it.id })
    }

    @Test
    fun `a replaced note with the same id is not taken for the old one`() {
        val memo = FeedThreadMemo()
        FeedThreadGrouping.build(listOf(note("a", 100)), memo = memo)
        val edited = note("a", 100, author = "carol")
        val again = FeedThreadGrouping.build(listOf(edited), memo = memo)
        assertSame(edited, again.single().root)
    }

    @Test
    fun `an empty feed clears the memo`() {
        val memo = FeedThreadMemo()
        val a = note("a", 100)
        val first = FeedThreadGrouping.build(listOf(a), memo = memo)
        FeedThreadGrouping.build(emptyList(), memo = memo)
        assertNotSame(first.single(), FeedThreadGrouping.build(listOf(a), memo = memo).single())
    }

    @Test
    fun `threadRootId is read once and stays the note's root`() {
        val r = note("r", 300, parent = "p", root = "top")
        assertEquals("top", r.threadRootId)
        assertSame(r.threadRootId, r.threadRootId)
        assertEquals("a", note("a", 1).threadRootId)
    }
}
