package com.nostrvault.service

import android.content.Context
import io.mockk.every
import io.mockk.mockk
import kotlinx.coroutines.async
import kotlinx.coroutines.awaitAll
import kotlinx.coroutines.runBlocking
import org.junit.Assert.assertArrayEquals
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Assert.fail
import org.junit.Test
import java.io.File
import java.nio.file.Files
import java.util.concurrent.atomic.AtomicInteger

/** Tron #2077 M1/S2: big locked photos can't run the app out of memory, and the cache stays capped. */
class DMFileLoaderLimitsTest {
    private val dir: File = Files.createTempDirectory("dmfiles").toFile()

    /** A locked file already in the cache, and its link. */
    private fun kept(plain: ByteArray): String {
        val enc = DMFile.encrypt(plain)
        File(dir, "dm_files").apply { mkdirs() }.resolve(enc.x).writeBytes(enc.cipher)
        return DMFile.fileLink("https://files.example/${enc.x}", enc.key, enc.nonce, enc.x, "image/png", enc.ox)
    }

    @Test
    fun `a file over the thread's limit is TooBig there and opens in the viewer`() = runBlocking {
        val ctx = mockk<Context> { every { cacheDir } returns dir }
        val plain = ByteArray((DMFileLoader.AUTO_SHOW_MAX + 1).toInt())
        val link = kept(plain)
        try {
            DMFileLoader.open(ctx, link, DMFileLoader.AUTO_SHOW_MAX)
            fail("should be TooBig")
        } catch (_: DMFileLoader.TooBig) {
        }
        assertArrayEquals(plain, DMFileLoader.open(ctx, link).first)
    }

    @Test
    fun `files open one at a time`() = runBlocking {
        val inside = AtomicInteger(0)
        val most = AtomicInteger(0)
        val ctx = mockk<Context> {
            every { cacheDir } answers {
                most.accumulateAndGet(inside.incrementAndGet(), ::maxOf)
                Thread.sleep(50)
                inside.decrementAndGet()
                dir
            }
        }
        val links = (1..4).map { kept(byteArrayOf(it.toByte())) }
        links.map { async(kotlinx.coroutines.Dispatchers.Default) { DMFileLoader.open(ctx, it) } }.awaitAll()
        assertEquals(1, most.get())
    }

    @Test
    fun `a video opening does not hold up locked photos`() = runBlocking {
        val release = java.util.concurrent.CountDownLatch(1)
        val videoCtx = mockk<Context> { every { cacheDir } answers { release.await(); dir } }
        val photoCtx = mockk<Context> { every { cacheDir } returns dir }
        val video = async(kotlinx.coroutines.Dispatchers.Default) { DMFileLoader.open(videoCtx, kept(byteArrayOf(7)), video = true) }
        val photo = kotlinx.coroutines.withTimeout(5_000) { DMFileLoader.open(photoCtx, kept(byteArrayOf(8))).first }
        assertArrayEquals(byteArrayOf(8), photo)
        release.countDown()
        assertArrayEquals(byteArrayOf(7), video.await().first)
    }

    @Test
    fun `the cache drops the least recently used files past its cap`() {
        val d = File(dir, "trim").apply { mkdirs() }
        val now = System.currentTimeMillis()
        val files = (0 until 4).map { i ->
            File(d, "f$i").apply { writeBytes(ByteArray(100)); setLastModified(now - (4 - i) * 10_000L) }
        }
        DMFileLoader.trim(d, 250)
        assertFalse(files[0].exists())
        assertFalse(files[1].exists())
        assertTrue(files[2].exists() && files[3].exists())
    }
}
