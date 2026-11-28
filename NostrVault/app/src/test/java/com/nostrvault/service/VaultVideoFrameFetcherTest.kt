package com.nostrvault.service

import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test
import java.io.File
import java.nio.file.Files

class VaultVideoFrameFetcherTest {
    private val sha = "a".repeat(64)

    @Test
    fun `a video tile asks for its frame, a photo for its file`() {
        val f = File("/data/relay/blossom/$sha")
        assertEquals(VaultVideoFrame(sha, f, f.path), VaultVideoFrameFetcher.tileData(sha, true, f, f.path))
        assertEquals(f, VaultVideoFrameFetcher.tileData(sha, false, f, f.path))
        val url = "https://blossom.example/$sha"
        assertEquals(VaultVideoFrame(sha, null, url), VaultVideoFrameFetcher.tileData(sha, true, null, url))
        assertEquals(url, VaultVideoFrameFetcher.tileData(sha, false, null, url))
    }

    @Test
    fun `frames live beside the blob folder, never in it`() {
        val dir = VaultVideoFrameFetcher.framesDirFor(File("/data/relay/blossom/$sha"))
        assertEquals(File("/data/relay/video_frames"), dir)
        assertEquals(File(dir, "$sha.jpg"), VaultVideoFrameFetcher.frameFile(dir, sha))
    }

    @Test
    fun `only a sha names a frame file`() {
        val dir = File("/x")
        assertNull(VaultVideoFrameFetcher.frameFile(dir, "../../etc/passwd"))
        assertNull(VaultVideoFrameFetcher.frameFile(dir, "abc"))
    }

    @Test
    fun `forget deletes the saved frame`() {
        val root = Files.createTempDirectory("vf").toFile()
        val blobs = File(root, "blossom").apply { mkdirs() }
        val frame = File(File(root, "video_frames").apply { mkdirs() }, "$sha.jpg").apply { writeText("x") }
        VaultVideoFrameFetcher.forget(blobs, sha)
        assertFalse(frame.exists())
        assertTrue(root.deleteRecursively())
    }
}
