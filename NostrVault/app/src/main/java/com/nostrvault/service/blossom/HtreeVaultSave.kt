package com.nostrvault.service

import android.content.Context
import com.nostrvault.data.model.HtreeLink
import java.io.File
import java.io.IOException

/**
 * Save to Vault for an `htree://` photo: the decrypted photo goes into the
 * vault on this phone under the plain sha256 the link carries (the CHK key),
 * so it is the same Blossom blob anyone else's copy of that photo is, and a
 * photo already in the vault is not fetched again. The encrypted blob is
 * never stored. Returns the sha256, or null when it could not be read or stored.
 */
internal suspend fun BlossomService.saveHtreeToLocal(context: Context, url: String): String? {
    val link = HtreeLink.parse(url) ?: return null
    val sha = link.plainSha256
    if (localBlobFile(sha) != null) return sha
    val photo = HtreeLoader.file(context, url) ?: return null
    var temp: File? = null
    return try {
        val copy = File.createTempFile("htree-${sha.take(12)}-", ".blob", BlobStream.tempDir()).also { temp = it }
        photo.copyTo(copy, overwrite = true)
        val mime = sniffImageFile(copy) ?: run { copy.delete(); return null }
        if (storeStreamed(StreamedBlob(copy, sha, copy.length()), mime, null)) sha else null
    } catch (e: IOException) {
        // Disk full, or the cache was trimmed under us: no crash, no temp left behind.
        temp?.delete()
        null
    }
}

/** The image type [file]'s first bytes say it is (never its name), or null. */
internal fun sniffImageFile(file: File): String? = try {
    val head = ByteArray(16)
    val n = file.inputStream().use { it.read(head) }
    HtreeLink.sniffImage(head.copyOf(maxOf(n, 0)))
} catch (e: IOException) {
    null
}
