package com.nostrvault.service

import com.nostrvault.data.local.ConfigStore
import io.mockk.every
import io.mockk.mockk
import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Before
import org.junit.Test
import java.io.File
import java.nio.file.Files

/** Settings → Clear Media Cache: the size it shows and what it removes (iOS MediaCacheService). */
class MediaCacheClearTest {

    private lateinit var root: File
    private lateinit var service: MediaCacheService

    @Before
    fun setUp() {
        root = Files.createTempDirectory("mediacache").toFile()
        val context = mockk<android.content.Context>(relaxed = true)
        every { context.cacheDir } returns root
        service = MediaCacheService(context, mockk<ConfigStore>(relaxed = true))
    }

    private fun write(file: File, bytes: Int) {
        file.parentFile?.mkdirs()
        file.writeBytes(ByteArray(bytes))
    }

    @Test
    fun `size counts the media cache and its thumbnails, nested files too`() {
        write(File(service.cacheDirectory, "a"), 1000)
        write(File(service.cacheDirectory, "sub/b"), 500)
        write(File(service.thumbnailDirectory, "c.jpg"), 250)
        write(File(root, "other/d"), 9999) // not the media cache
        assertEquals(1750L, service.cacheSizeBytes())
    }

    @Test
    fun `clear empties both directories and reports what it freed`() {
        write(File(service.cacheDirectory, "a"), 1000)
        write(File(service.cacheDirectory, "sub/b"), 500)
        write(File(service.thumbnailDirectory, "c.jpg"), 250)
        val other = File(root, "other/d").also { write(it, 9999) }

        val result = service.clearCache()

        assertEquals(1750L, result.bytesFreed)
        assertEquals(0, result.filesFailed)
        assertEquals(0L, service.cacheSizeBytes())
        assertTrue(service.cacheDirectory.listFiles().isNullOrEmpty())
        assertTrue(service.thumbnailDirectory.listFiles().isNullOrEmpty())
        assertTrue(other.exists())
    }
}
