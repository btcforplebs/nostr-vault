package com.nostrvault.ui.screens

import org.junit.Assert.assertEquals
import org.junit.Test
import java.io.File

/** Copy link on a vault photo whose Mac relay address is an onion (user report 2026-10-31). */
class PublicBlossomLinkTest {
    private val sha = "a".repeat(64)
    private val onion = "abcdefghijklmnopqrstuvwxyzabcdefghijklmnopqrstuvwxyz56.onion"

    private fun item(url: String, file: File? = null) = BlossomMediaItem(
        sha256 = sha, displayUrl = url, localFile = file, mimeType = "image/jpeg",
        size = null, uploaded = null, lastModified = null, isLocal = file != null,
    )

    @Test
    fun localFileOnAnOnionMirrorKeepsTheHashAndUsesHttp() {
        val local = item("/data/blossom/$sha", File("/data/blossom/$sha"))
        assertEquals("http://$onion/$sha", publicBlossomLink(local, listOf("https://$onion")))
        assertEquals("http://$onion:4869/$sha", publicBlossomLink(local, listOf("https://$onion:4869/")))
    }

    @Test
    fun aListedUrlWithoutTheHashFallsBackToMirrorAndHash() {
        assertEquals("http://$onion/$sha", publicBlossomLink(item("https://$onion"), listOf("https://$onion")))
        assertEquals("https://b.example/$sha", publicBlossomLink(item("https://$onion/"), listOf("https://b.example")))
    }

    @Test
    fun aListedOnionUrlWithTheHashUsesHttp() {
        assertEquals("http://$onion/$sha.jpg", publicBlossomLink(item("https://$onion/$sha.jpg"), emptyList()))
    }

    @Test
    fun clearnetLinksAreUnchanged() {
        assertEquals("https://b.example/$sha.png", publicBlossomLink(item("https://b.example/$sha.png"), listOf("https://$onion")))
        assertEquals("https://b.example/$sha", publicBlossomLink(item("/data/$sha", File("/data/$sha")), listOf("http://127.0.0.1:3355", "https://b.example")))
        assertEquals("https://onion.example.com/$sha", publicBlossomLink(item("https://onion.example.com/$sha"), emptyList()))
        assertEquals("/data/$sha", publicBlossomLink(item("/data/$sha", File("/data/$sha")), emptyList()))
    }

    @Test
    fun overTorOnlyTouchesOnionHttps() {
        assertEquals("http://$onion/x", overTor("https://$onion/x"))
        assertEquals("http://$onion/x", overTor("http://$onion/x"))
        assertEquals("https://a.onion.example/x", overTor("https://a.onion.example/x"))
    }
}
