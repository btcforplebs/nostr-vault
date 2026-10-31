package com.nostrvault.service

import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Test

class ServerListAdoptionTest {

    @Test
    fun `their list replaces ours, in their order`() {
        // A new install's defaults, then their own list from another app: theirs, first one first.
        val result = ServerListAdoption.adopt(
            local = listOf("https://blossom.primal.net", "https://blossom.nostr.build"),
            updatedAt = null,
            published = listOf("https://cdn.theirs.example", "https://blossom.primal.net/"),
            publishedAt = 200,
            base = null,
        )!!
        assertEquals(listOf("https://cdn.theirs.example", "https://blossom.primal.net/"), result.mirrors)
        assertEquals(listOf("https://cdn.theirs.example"), result.added)
        assertEquals(200L, result.updatedAt)
    }

    @Test
    fun `a list with no usable server keeps ours`() {
        val local = listOf("https://blossom.nostr.build")
        assertNull(ServerListAdoption.adopt(local, null, listOf("fipsmesh://npub1x/", "http://127.0.0.1:3355"), 5, null))
    }

    @Test
    fun `a list no newer than the last change here changes nothing`() {
        assertNull(ServerListAdoption.adopt(emptyList(), 200, listOf("https://a.example"), 200, null))
        assertNull(ServerListAdoption.adopt(emptyList(), 300, listOf("https://a.example"), 200, null))
    }

    @Test
    fun `never set here adopts any list`() {
        val result = ServerListAdoption.adopt(emptyList(), null, listOf("https://a.example"), 5, null)!!
        assertEquals(listOf("https://a.example"), result.mirrors)
    }

    @Test
    fun `a server removed here is not added back`() {
        val result = ServerListAdoption.adopt(
            local = listOf("https://keep.example"),
            updatedAt = 100,
            published = listOf("https://keep.example", "https://removed.example", "https://new.example"),
            publishedAt = 200,
            base = listOf("https://keep.example", "https://Removed.example/"),
        )!!
        assertEquals(listOf("https://keep.example", "https://new.example"), result.mirrors)
        assertEquals(listOf("https://new.example"), result.added)
    }

    @Test
    fun `own relay, loopback and non-http entries are skipped`() {
        val result = ServerListAdoption.adopt(
            local = emptyList(),
            updatedAt = null,
            published = listOf(
                "https://mac.example:4869", "http://127.0.0.1:3355", "wss://relay.example",
                "not a url", "https://a.example", "https://a.example",
            ),
            publishedAt = 10,
            base = null,
            ownServers = listOf("https://mac.example:4869/"),
        )!!
        assertEquals(listOf("https://a.example"), result.added)
    }

    @Test
    fun `nothing new still stamps the list as seen`() {
        val result = ServerListAdoption.adopt(listOf("https://a.example"), 1, listOf("https://a.example"), 9, null)!!
        assertEquals(emptyList<String>(), result.added)
        assertEquals(9L, result.updatedAt)
    }
}
