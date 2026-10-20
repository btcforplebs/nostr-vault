package com.nostrvault.service

import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Test
import java.io.File
import java.nio.file.Files

/**
 * NIP-51 lists are replaceable: publishing only this device's entries used to
 * delete what other clients had set (review items D3, P3).
 */
class ListMergeTest {
    @Test
    fun `mute list keeps word, hashtag and thread mutes and replaces the p tags`() {
        val published = listOf(
            listOf("p", "aaa"), listOf("p", "gone"),
            listOf("word", "spoiler"), listOf("t", "nsfw"), listOf("e", "thread1"),
        )
        val tags = ListMerge.tags("p", listOf("aaa", "bbb"), published) { false }
        assertEquals(
            listOf(
                listOf("p", "aaa"), listOf("p", "bbb"),
                listOf("word", "spoiler"), listOf("t", "nsfw"), listOf("e", "thread1"),
            ),
            tags,
        )
    }

    @Test
    fun `an entry another client added stays, one removed here goes`() {
        val base = setOf("wss://removed.example", "wss://kept.example")
        val published = listOf(
            listOf("relay", "wss://kept.example"),
            listOf("relay", "wss://removed.example"),
            listOf("relay", "wss://other-client.example"),
        )
        val tags = ListMerge.tags("relay", listOf("wss://kept.example"), published) { ListMerge.key(it) !in base }
        assertEquals(
            listOf(listOf("relay", "wss://kept.example"), listOf("relay", "wss://other-client.example")),
            tags,
        )
    }

    @Test
    fun `no base yet keeps every published entry, once, after the local ones in order`() {
        val published = listOf(listOf("server", "https://b.example/"), listOf("server", "https://c.example"))
        val tags = ListMerge.tags("server", listOf("https://a.example", "https://B.example"), published) { true }
        assertEquals(
            listOf(listOf("server", "https://a.example"), listOf("server", "https://B.example"), listOf("server", "https://c.example")),
            tags,
        )
    }

    @Test
    fun `nothing published publishes the local list`() {
        assertEquals(listOf(listOf("p", "x")), ListMerge.tags("p", listOf("x", "X", " "), emptyList()) { true })
    }

    @Test
    fun `bases are saved per list and survive a new instance`() {
        val file = File(Files.createTempDirectory("bases").toFile(), ListMerge.BASES_FILE)
        assertNull(ListMerge.Bases(file).get("10006:abc"))
        ListMerge.Bases(file).put("10006:abc", listOf("wss://a"))
        ListMerge.Bases(file).put("10063:abc", listOf("https://m"))
        assertEquals(listOf("wss://a"), ListMerge.Bases(file).get("10006:abc"))
        assertEquals(listOf("https://m"), ListMerge.Bases(file).get("10063:abc"))
    }
}
