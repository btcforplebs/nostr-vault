package com.nostrvault.service

import kotlinx.coroutines.runBlocking
import okhttp3.OkHttpClient
import okhttp3.Request
import okhttp3.mockwebserver.MockResponse
import okhttp3.mockwebserver.MockWebServer
import okio.Buffer
import org.junit.After
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Before
import org.junit.Test
import java.io.File
import java.io.InputStream
import java.nio.file.Files
import java.security.MessageDigest

/**
 * Big media into the vault (Logen, 2026-11-06): a file over the old 50 MB cap
 * is streamed to disk through one small buffer, hash-checked, and handed to
 * the vault by path; nothing ever holds the whole file in memory.
 */
class BlobStreamTest {
    private lateinit var dir: File

    @Before fun setUp() { dir = Files.createTempDirectory("blobstream").toFile() }

    @After fun tearDown() { dir.deleteRecursively() }

    private val mb = 1024L * 1024
    private val plenty = { 100L * 1024 * mb }

    /**
     * [size] deterministic bytes, made on the fly (never a whole array), that
     * records the largest read it was asked for and the heap in use.
     */
    private class Generated(val size: Long) : InputStream() {
        var pos = 0L
        var largestRead = 0
        var peakHeap = 0L
        private val rt = Runtime.getRuntime()
        override fun read(): Int = if (pos >= size) -1 else byteAt(pos++)
        override fun read(b: ByteArray, off: Int, len: Int): Int {
            if (pos >= size) return -1
            largestRead = maxOf(largestRead, len)
            val n = minOf(len.toLong(), size - pos).toInt()
            for (i in 0 until n) b[off + i] = byteAt(pos + i).toByte()
            pos += n
            if (pos % (8 * 1024 * 1024) < n) peakHeap = maxOf(peakHeap, rt.totalMemory() - rt.freeMemory())
            return n
        }
        companion object {
            fun byteAt(i: Long): Int = ((i * 31 + (i shr 13)) and 0xff).toInt()
            fun sha(size: Long): String {
                val d = MessageDigest.getInstance("SHA-256")
                val buf = ByteArray(64 * 1024)
                var p = 0L
                while (p < size) {
                    val n = minOf(buf.size.toLong(), size - p).toInt()
                    for (i in 0 until n) buf[i] = byteAt(p + i).toByte()
                    d.update(buf, 0, n); p += n
                }
                return d.digest().joinToString("") { "%02x".format(it) }
            }
        }
    }

    private fun heapNow(): Long { System.gc(); val rt = Runtime.getRuntime(); return rt.totalMemory() - rt.freeMemory() }

    @Test
    fun `a 200 MB file streams to disk through one small buffer, hash-checked, and is stored by path`() = runBlocking {
        val size = 200 * mb
        val want = Generated.sha(size)
        val before = heapNow()
        val input = Generated(size)
        val got = BlobStream.toTempFile(input, size, dir, expectSha = want, freeBytes = plenty)
        assertTrue("streamed: $got", got is StreamResult.Ok)
        val blob = (got as StreamResult.Ok).blob
        assertEquals(want, blob.sha256)
        assertEquals(size, blob.size)
        assertEquals(size, blob.file.length())
        assertTrue("one small buffer (largest read ${input.largestRead})", input.largestRead <= BlobStream.BUFFER_BYTES)
        // A whole-file read would add 200 MB; allow GC slack well below that.
        assertTrue("heap grew ${(input.peakHeap - before) / mb} MB", input.peakHeap - before < 48 * mb)

        // Over the old cap on this phone's own vault: the engine takes it by path, not an HTTP PUT.
        assertTrue(BlobStream.storesInProcess(keyless = false, externalRelay = false, size = size))
        var handed: Triple<String, String, String>? = null
        var hashedAtStore = ""
        val stored = BlobStream.store(blob, "video/mp4", viaEngine = true, inProcess = { path, sha, type ->
            handed = Triple(path, sha, type)
            hashedAtStore = sha256Of(File(path))
            true
        }) { error("no HTTP upload for a big file on this phone") }
        assertTrue(stored)
        assertEquals(want, handed!!.second)
        assertEquals("video/mp4", handed!!.third)
        assertEquals("the file the vault read is the one hashed", want, hashedAtStore)
        assertFalse("temp file deleted after the store", File(handed!!.first).exists())
        assertEquals(0, dir.listFiles()!!.size)
    }

    @Test
    fun `through OkHttp too, a 64 MB body is streamed, not read into memory`() {
        val size = 64 * mb
        val server = MockWebServer()
        val body = Buffer()
        val chunk = ByteArray(64 * 1024)
        var p = 0L
        while (p < size) { for (i in chunk.indices) chunk[i] = Generated.byteAt(p + i).toByte(); body.write(chunk); p += chunk.size }
        server.enqueue(MockResponse().setBody(body))
        server.start()
        try {
            val response = OkHttpClient().newCall(Request.Builder().url(server.url("/x")).build()).execute()
            val got = BlobStream.toTempFile(response.body!!.byteStream(), response.body!!.contentLength(), dir, Generated.sha(size), plenty)
            assertTrue("$got", got is StreamResult.Ok)
            assertEquals(size, (got as StreamResult.Ok).blob.file.length())
            got.blob.delete()
        } finally {
            server.shutdown()
        }
    }

    @Test
    fun `no room for two copies, skipped before a byte is written, with the reason`() {
        val size = 300 * mb
        val input = Generated(size)
        val got = BlobStream.toTempFile(input, size, dir, freeBytes = { 500 * mb })
        assertTrue(got is StreamResult.Skipped)
        assertTrue((got as StreamResult.Skipped).reason, got.reason.startsWith("not enough free storage"))
        assertEquals("nothing read", 0L, input.pos)
        assertEquals(0, dir.listFiles()!!.size)
    }

    @Test
    fun `unknown length, the disk is re-checked as it arrives, and the temp file goes`() {
        var free = 512 * mb
        val input = Generated(400 * mb)
        val got = BlobStream.toTempFile(input, -1, dir, freeBytes = { free.also { free -= 16 * mb } })
        // Not a strict point; it must stop well before the whole file and leave nothing.
        assertTrue(got is StreamResult.Skipped)
        assertTrue(input.pos < 400 * mb)
        assertEquals(0, dir.listFiles()!!.size)
    }

    @Test
    fun `failures leave no temp file`() = runBlocking {
        // Wrong hash (a bad mirror).
        assertTrue(BlobStream.toTempFile(Generated(mb), mb, dir, expectSha = "0".repeat(64), freeBytes = plenty) is StreamResult.Skipped)
        // Cut short.
        assertTrue(BlobStream.toTempFile(Generated(mb), 2 * mb, dir, freeBytes = plenty) is StreamResult.Skipped)
        // Longer than it said.
        assertTrue(BlobStream.toTempFile(Generated(2 * mb), mb, dir, freeBytes = plenty) is StreamResult.Skipped)
        // The connection drops mid-file.
        val dropping = object : InputStream() {
            var n = 0
            override fun read(): Int = throw UnsupportedOperationException()
            override fun read(b: ByteArray, off: Int, len: Int): Int { if (n++ > 3) throw java.io.IOException("reset"); return len }
        }
        runCatching { BlobStream.toTempFile(dropping, -1, dir, freeBytes = plenty) }
        assertEquals(0, dir.listFiles()!!.size)

        // The vault refuses it, or throws: the temp file still goes.
        for (refuse in listOf<(String, String, String) -> Boolean>({ _, _, _ -> false }, { _, _, _ -> error("boom") })) {
            val blob = (BlobStream.toTempFile(Generated(mb), mb, dir, freeBytes = plenty) as StreamResult.Ok).blob
            assertFalse(BlobStream.store(blob, "image/jpeg", viaEngine = true, inProcess = refuse) { true })
            assertFalse(blob.file.exists())
        }
        assertEquals(0, dir.listFiles()!!.size)
    }

    @Test
    fun `which way into the vault`() {
        val big = 51 * mb
        val small = 5 * mb
        assertTrue("keyless always in-process", BlobStream.storesInProcess(keyless = true, externalRelay = true, size = small))
        assertTrue("big on this phone: in-process", BlobStream.storesInProcess(keyless = false, externalRelay = false, size = big))
        assertFalse("small signed: HTTP from the file, as before", BlobStream.storesInProcess(keyless = false, externalRelay = false, size = small))
        assertFalse("external relay: HTTP from the file", BlobStream.storesInProcess(keyless = false, externalRelay = true, size = big))
    }

    @Test
    fun `big files go one at a time, and a failed one gives its turn back`() = runBlocking {
        val gate = BigFileGate()
        val big = BlobStream.BIG_BYTES + mb
        val first = (BlobStream.toTempFile(Generated(big), big, dir, freeBytes = plenty, gate = gate) as StreamResult.Ok).blob

        // A second big file waits its turn: told Busy before a byte is read, nothing left on disk.
        val second = Generated(big)
        assertEquals(StreamResult.Busy, BlobStream.toTempFile(second, big, dir, freeBytes = plenty, gate = gate))
        assertEquals(0L, second.pos)
        // No length given: it finds out it is big on the way, stops, and its temp file goes.
        val chunked = Generated(big)
        assertEquals(StreamResult.Busy, BlobStream.toTempFile(chunked, -1, dir, freeBytes = plenty, gate = gate))
        assertTrue(chunked.pos <= BlobStream.BIG_BYTES + BlobStream.BUFFER_BYTES)
        assertEquals(listOf(first.file), dir.listFiles()!!.toList())
        // Small files are not held up.
        assertTrue(BlobStream.toTempFile(Generated(mb), mb, dir, freeBytes = plenty, gate = gate) is StreamResult.Ok)

        // Once the first is stored, the next big file goes in.
        assertTrue(BlobStream.store(first, "video/mp4", viaEngine = true, inProcess = { _, _, _ -> true }) { false })
        val next = BlobStream.toTempFile(Generated(big), big, dir, freeBytes = plenty, gate = gate)
        assertTrue("$next", next is StreamResult.Ok)
        (next as StreamResult.Ok).blob.delete()

        // A big file that fails (bad hash, no room) gives the turn back.
        assertTrue(BlobStream.toTempFile(Generated(big), big, dir, "0".repeat(64), plenty, gate) is StreamResult.Skipped)
        assertTrue(BlobStream.toTempFile(Generated(big), big, dir, freeBytes = { 10 * mb }, gate = gate) is StreamResult.Skipped)
        assertTrue("turn free again", gate.tryTake())
    }

    @Test
    fun `an import sweeps temp files a killed import left, never a running one`() {
        val leftover = File(dir, "import-123.blob").apply { writeBytes(ByteArray(1024)) }
        val other = File(dir, "photo.jpg").apply { writeBytes(ByteArray(10)) }
        val running = (BlobStream.toTempFile(Generated(mb), mb, dir, freeBytes = plenty) as StreamResult.Ok).blob
        assertEquals(1, BlobStream.sweepLeftovers(dir))
        assertFalse(leftover.exists())
        assertTrue(other.exists())
        assertTrue("a download still on its way in is kept", running.file.exists())
        running.delete()
        assertEquals(0, BlobStream.sweepLeftovers(dir))
    }

    private fun sha256Of(f: File): String {
        val d = MessageDigest.getInstance("SHA-256")
        f.inputStream().use { s -> val b = ByteArray(64 * 1024); while (true) { val n = s.read(b); if (n < 0) break; d.update(b, 0, n) } }
        return d.digest().joinToString("") { "%02x".format(it) }
    }
}
