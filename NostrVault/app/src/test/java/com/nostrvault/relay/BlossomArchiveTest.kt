package com.nostrvault.relay

import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Rule
import org.junit.Test
import org.junit.rules.TemporaryFolder
import java.io.File
import java.security.MessageDigest
import java.util.zip.ZipEntry
import java.util.zip.ZipFile
import java.util.zip.ZipOutputStream

/** Media backups must restore across iOS and Android (iOS runBlossomExportWithExtensions). */
class BlossomArchiveTest {
    @get:Rule val tmp = TemporaryFolder()

    private val jpeg = byteArrayOf(0xFF.toByte(), 0xD8.toByte(), 0xFF.toByte(), 0xE0.toByte()) + "jpeg body".toByteArray()
    private val text = "not a known format".toByteArray()

    private fun sha(bytes: ByteArray) =
        MessageDigest.getInstance("SHA-256").digest(bytes).joinToString("") { "%02x".format(it) }

    private fun zip(entries: Map<String, ByteArray>): File {
        val f = tmp.newFile()
        ZipOutputStream(f.outputStream()).use { z ->
            entries.forEach { (name, bytes) ->
                z.putNextEntry(ZipEntry(name)); z.write(bytes); z.closeEntry()
            }
        }
        return f
    }

    @Test
    fun `export names each blob sha dot extension like iOS`() {
        val dir = tmp.newFolder("blossom")
        File(dir, sha(jpeg)).writeBytes(jpeg)
        File(dir, sha(text)).writeBytes(text)
        File(dir, ".hidden").writeBytes(text)
        val out = File(tmp.root, "out.zip")

        assertEquals(2, BlossomArchive.export(dir, out))

        val names = ZipFile(out).use { z -> z.entries().toList().map { it.name }.toSet() }
        assertEquals(setOf("${sha(jpeg)}.jpeg", sha(text)), names)
    }

    @Test
    fun `an iOS backup restores with the extensions stripped`() {
        val archive = zip(mapOf("${sha(jpeg)}.jpeg" to jpeg, "${sha(text)}.bin" to text))
        val dir = tmp.newFolder("restore")

        val result = BlossomArchive.import(archive, dir)

        assertEquals(BlossomArchive.ImportResult(imported = 2, skipped = 0), result)
        assertTrue(File(dir, sha(jpeg)).readBytes().contentEquals(jpeg))
        assertTrue(File(dir, sha(text)).exists())
        assertEquals(2, dir.listFiles()!!.size)
    }

    @Test
    fun `an old Android backup with bare names still restores`() {
        val archive = zip(mapOf(sha(jpeg) to jpeg))
        val dir = tmp.newFolder("restore")

        assertEquals(1, BlossomArchive.import(archive, dir).imported)
        assertTrue(File(dir, sha(jpeg)).exists())
    }

    @Test
    fun `round trip through export and import keeps every blob`() {
        val src = tmp.newFolder("src")
        File(src, sha(jpeg)).writeBytes(jpeg)
        File(src, sha(text)).writeBytes(text)
        val archive = File(tmp.root, "rt.zip")
        BlossomArchive.export(src, archive)
        val dest = tmp.newFolder("dest")

        assertEquals(2, BlossomArchive.import(archive, dest).imported)
        assertEquals(src.list()!!.toSet(), dest.list()!!.toSet())
    }

    @Test
    fun `entries that are not a matching sha256 are skipped`() {
        val archive = zip(
            mapOf(
                "../${sha(jpeg)}.jpeg" to jpeg, // path is dropped, the blob lands in the folder
                "${"0".repeat(64)}.jpeg" to jpeg, // bytes don't hash to the name
                "photo.jpeg" to jpeg,
                "${sha(text).uppercase()}.bin" to text,
                "__MACOSX/._${sha(text)}" to text,
            ),
        )
        val dir = tmp.newFolder("restore")

        val result = BlossomArchive.import(archive, dir)

        assertEquals(BlossomArchive.ImportResult(imported = 1, skipped = 3), result)
        assertEquals(listOf(sha(jpeg)), dir.list()!!.toList())
        assertFalse(File(tmp.root, sha(jpeg)).exists())
    }

    @Test
    fun `magic bytes pick the extension`() {
        fun ext(vararg b: Int) = BlossomArchive.extensionFor(ByteArray(16) { i -> (b.getOrElse(i) { 0 }).toByte() })
        assertEquals("png", ext(0x89, 0x50, 0x4E, 0x47))
        assertEquals("gif", ext(0x47, 0x49, 0x46, 0x38))
        assertEquals("webp", ext(0x52, 0x49, 0x46, 0x46, 0, 0, 0, 0, 0x57, 0x45, 0x42, 0x50))
        assertEquals("mov", ext(0, 0, 0, 16, 0x66, 0x74, 0x79, 0x70, 0x71, 0x74, 0x20, 0x20))
        assertEquals("mp4", ext(0, 0, 0, 16, 0x66, 0x74, 0x79, 0x70, 0x69, 0x73, 0x6F, 0x6D))
        assertNull(ext(0x01, 0x02, 0x03, 0x04))
    }
}
