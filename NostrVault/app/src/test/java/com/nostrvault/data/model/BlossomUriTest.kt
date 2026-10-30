package com.nostrvault.data.model

import com.nostrvault.ui.components.ContentSegment
import com.nostrvault.ui.components.parseContentSegments
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

/** BUD-10 `blossom:` links. Same cases as iOS BlossomURITests and web blossom-uri.test.mjs. */
class BlossomUriTest {
    private val sha = "d819b9226a3e1f7c0b5d4e2a9c8f7b6a5d4c3b2a1f0e9d8c7b6a5f4e3d2c1b0a"
    private val pub = "27e32ae5911bd8557e5b61ce5c7b2b67c61ced37829af68ebd5992164386d6d2"

    @Test
    fun `parses hash, extension, servers, author and size`() {
        val uri = BlossomUri.parse("blossom:${sha.uppercase()}.JPG?xs=blossom.example.com&xs=https://cdn.example.org/&as=$pub&sz=117475")!!
        assertEquals(sha, uri.sha256)
        assertEquals("jpg", uri.ext)
        assertEquals(listOf("https://blossom.example.com", "https://cdn.example.org"), uri.servers)
        assertEquals(pub, uri.author)
        assertEquals(117475L, uri.size)
    }

    @Test
    fun `malformed links are not links`() {
        assertNull(BlossomUri.parse("blossom:abc.jpg"))
        assertNull(BlossomUri.parse("blossom:$sha"))
        assertNull(BlossomUri.parse("https://x.com/$sha.jpg"))
        // A non-hex `as` is dropped, the link stays.
        assertNull(BlossomUri.parse("blossom:$sha.png?as=npub1xyz")!!.author)
    }

    @Test
    fun `loopback, private and http servers are never asked`() {
        val refused = listOf(
            "http://blossom.example.com", "localhost", "127.0.0.1:24242", "10.0.0.5", "192.168.1.2",
            "172.20.0.1", "100.64.0.1", "169.254.1.1", "[::1]", "[fd12:3456::1]", "[fe80::1]",
            "box.local", "abc.onion", "intranet", "ftp://files.example.com", "https://u:p@example.com",
        )
        for (s in refused) assertNull(s, BlossomUri.serverOrigin(s))
        assertEquals("https://example.com", BlossomUri.serverOrigin("example.com/"))
        assertEquals("https://example.com:8443/b", BlossomUri.serverOrigin("https://example.com:8443/b/"))
        assertEquals(emptyList<String>(), BlossomUri.parse("blossom:$sha.jpg?xs=127.0.0.1&xs=http://a.com")!!.servers)
    }

    @Test
    fun `candidates are the link's servers, then the author's, then ours, once each`() {
        val uri = BlossomUri.parse("blossom:$sha.mp4?xs=a.com")!!
        assertEquals(
            listOf("https://a.com/$sha.mp4", "https://b.com/$sha.mp4", "https://c.com/$sha.mp4"),
            uri.candidates(listOf("https://A.com/", "b.com", "http://insecure.com"), listOf("https://c.com", "https://b.com")),
        )
    }

    @Test
    fun `a media link is note media and leaves the text`() {
        val link = "blossom:$sha.jpg?xs=blossom.laantungir.net&sz=117475"
        val content = "Look at this $link nice"
        assertEquals(listOf(link), FeedNote.parseMediaURLs(content))
        val text = parseContentSegments(content, setOf(link))
            .filterIsInstance<ContentSegment.PlainText>().joinToString("") { it.text }
        assertEquals("Look at this nice", text)
    }

    @Test
    fun `a non-media link stays text`() {
        val link = "blossom:$sha.pdf?xs=a.com"
        assertEquals(emptyList<String>(), FeedNote.parseMediaURLs("doc $link"))
        val text = parseContentSegments("doc $link", emptySet())
            .filterIsInstance<ContentSegment.PlainText>().joinToString("") { it.text }
        assertTrue(text.contains(link))
    }

    @Test
    fun `the note author is remembered for links without as`() {
        val link = "blossom:${sha.reversed()}.png"
        BlossomUri.register(listOf(link), pub)
        assertEquals(pub, BlossomUri.noteAuthor(sha.reversed()))
    }
}
