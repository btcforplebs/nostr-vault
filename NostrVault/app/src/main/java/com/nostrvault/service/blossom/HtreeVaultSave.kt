package com.nostrvault.service

import android.content.Context
import com.nostrvault.data.model.HtreeLink
import java.io.File

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
    val temp = File.createTempFile("htree-${sha.take(12)}-", ".blob", BlobStream.tempDir())
    photo.copyTo(temp, overwrite = true)
    val head = ByteArray(16)
    val n = temp.inputStream().use { it.read(head) }
    val mime = HtreeLink.sniffImage(head.copyOf(maxOf(n, 0))) ?: run { temp.delete(); return null }
    return if (storeStreamed(StreamedBlob(temp, sha, temp.length()), mime, null)) sha else null
}
