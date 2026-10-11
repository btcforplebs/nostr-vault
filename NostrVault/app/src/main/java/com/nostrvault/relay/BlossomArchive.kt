package com.nostrvault.relay

import java.io.File
import java.io.IOException
import java.nio.file.Files
import java.nio.file.StandardCopyOption
import java.security.MessageDigest
import java.util.zip.Deflater
import java.util.zip.ZipEntry
import java.util.zip.ZipInputStream
import java.util.zip.ZipOutputStream

/**
 * Media (Blossom) backups in the format iOS reads and writes, so a backup from
 * either platform restores on the other. The vault stores each blob under its
 * bare sha256; the archive names it `<sha256>.<ext>` (extension from the file's
 * magic bytes, none when unknown) and a restore strips the extension again.
 * Backups made by older Android builds, with bare names, restore too.
 * iOS: runBlossomExportWithExtensions / runBlossomImportStrippingExtensions
 * (RelayProcessManager+BlossomTransfer.swift).
 */
object BlossomArchive {

    data class ImportResult(val imported: Int, val skipped: Int)

    private val SHA256_NAME = Regex("^[a-f0-9]{64}$")

    /** Write every blob in [blossomDir] to the zip at [zipFile]; returns the count. */
    fun export(blossomDir: File, zipFile: File): Int {
        val blobs = blossomDir.listFiles()
            ?.filter { it.isFile && !it.name.startsWith(".") }
            ?.sortedBy { it.name }
            ?: throw IOException("Media folder not found: ${blossomDir.path}")
        ZipOutputStream(zipFile.outputStream().buffered()).use { zip ->
            // Media is already compressed; deflating it again only costs time.
            zip.setLevel(Deflater.NO_COMPRESSION)
            for (blob in blobs) {
                val ext = extensionFor(blob)
                zip.putNextEntry(ZipEntry(if (ext == null) blob.name else "${blob.name}.$ext"))
                blob.inputStream().use { it.copyTo(zip) }
                zip.closeEntry()
            }
        }
        return blobs.size
    }

    /**
     * Restore the blobs in [zipFile] into [blossomDir], replacing any with the
     * same hash. Entries whose name (minus extension) isn't a lowercase sha256,
     * or whose bytes don't hash to it, are skipped, so nothing in the archive
     * can write outside the folder or serve wrong bytes under a hash.
     */
    fun import(zipFile: File, blossomDir: File): ImportResult {
        blossomDir.mkdirs()
        var imported = 0
        var skipped = 0
        ZipInputStream(zipFile.inputStream().buffered()).use { zip ->
            while (true) {
                val entry = zip.nextEntry ?: break
                val path = entry.name.replace('\\', '/')
                val name = path.substringAfterLast('/')
                if (entry.isDirectory || name.isEmpty() || name.startsWith(".") ||
                    path.split('/').contains("__MACOSX")
                ) {
                    continue
                }
                val sha = name.substringBeforeLast('.')
                if (!SHA256_NAME.matches(sha)) {
                    skipped++
                    continue
                }
                val tmp = File(blossomDir, ".$sha.restoring")
                val digest = MessageDigest.getInstance("SHA-256")
                try {
                    tmp.outputStream().use { out ->
                        val buf = ByteArray(64 * 1024)
                        while (true) {
                            val n = zip.read(buf)
                            if (n < 0) break
                            digest.update(buf, 0, n)
                            out.write(buf, 0, n)
                        }
                    }
                    val actual = digest.digest().joinToString("") { "%02x".format(it) }
                    if (actual == sha) {
                        Files.move(
                            tmp.toPath(), File(blossomDir, sha).toPath(),
                            StandardCopyOption.REPLACE_EXISTING, StandardCopyOption.ATOMIC_MOVE,
                        )
                        imported++
                    } else {
                        skipped++
                    }
                } finally {
                    tmp.delete()
                }
            }
        }
        return ImportResult(imported, skipped)
    }

    /** The extension for a blob, from its magic bytes; null when unknown. iOS detectMimeFromBytes. */
    internal fun extensionFor(file: File): String? {
        val header = ByteArray(64)
        val n = file.inputStream().use { it.read(header) }
        return if (n < 4) null else extensionFor(header.copyOf(n))
    }

    internal fun extensionFor(b: ByteArray): String? {
        fun at(i: Int) = b[i].toInt() and 0xFF
        fun startsWith(vararg sig: Int) = b.size >= sig.size && sig.indices.all { at(it) == sig[it] }
        fun ascii(from: Int) = String(b, from, 4, Charsets.US_ASCII)
        return when {
            startsWith(0xFF, 0xD8, 0xFF) -> "jpeg"
            startsWith(0x89, 0x50, 0x4E, 0x47) -> "png"
            startsWith(0x47, 0x49, 0x46, 0x38) -> "gif"
            b.size >= 12 && startsWith(0x52, 0x49, 0x46, 0x46) -> when (ascii(8)) {
                "WEBP" -> "webp"
                "WAVE" -> "wav"
                else -> null
            }
            b.size >= 12 && ascii(4) == "ftyp" -> ftypExtension(b)
            startsWith(0x1A, 0x45, 0xDF, 0xA3) -> "webm"
            startsWith(0x25, 0x50, 0x44, 0x46) -> "pdf"
            startsWith(0x49, 0x44, 0x33) -> "mp3"
            at(0) == 0xFF && (at(1) and 0xE0) == 0xE0 -> "mp3"
            startsWith(0x49, 0x49, 0x2A, 0x00) || startsWith(0x4D, 0x4D, 0x00, 0x2A) -> "tiff"
            startsWith(0x42, 0x4D) -> "bmp"
            startsWith(0x66, 0x4C, 0x61, 0x43) -> "flac"
            startsWith(0x4F, 0x67, 0x67, 0x53) -> "ogg"
            startsWith(0x50, 0x4B, 0x03, 0x04) -> "zip"
            startsWith(0x1F, 0x8B) -> "gz"
            else -> null
        }
    }

    /** Major and compatible brands of an ftyp box. iOS classifyFtyp. */
    private fun ftypExtension(b: ByteArray): String {
        val boxSize = minOf(
            ((b[0].toInt() and 0xFF) shl 24) or ((b[1].toInt() and 0xFF) shl 16) or
                ((b[2].toInt() and 0xFF) shl 8) or (b[3].toInt() and 0xFF),
            b.size,
        )
        val brands = buildSet {
            if (boxSize >= 12) add(String(b, 8, 4, Charsets.US_ASCII))
            var offset = 16
            while (offset + 4 <= boxSize) {
                add(String(b, offset, 4, Charsets.US_ASCII))
                offset += 4
            }
        }
        return when {
            "avif" in brands || "avis" in brands -> "avif"
            "heic" in brands || "heix" in brands -> "heic"
            "qt  " in brands -> "mov"
            else -> "mp4"
        }
    }
}
