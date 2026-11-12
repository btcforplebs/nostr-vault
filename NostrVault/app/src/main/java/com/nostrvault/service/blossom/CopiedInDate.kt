package com.nostrvault.service

import android.util.Log
import com.nostrvault.service.BlossomService.Companion.TAG
import java.io.File

/**
 * The date a blob copied into this vault carries on disk. Port of iOS
 * `CopiedInDate`.
 *
 * The Media tab dates a file that no seen note posted by its modified time.
 * A copy written now made an old photo jump to the top, so copy-ins stamp the
 * file with the photo's own date instead: the newest note's `created_at` that
 * links it, or the earliest BUD-02 `uploaded` time any server lists for it.
 */
internal object CopiedInDate {
    /** Seconds: the newest date per key, so a photo used in several notes gets one date. */
    fun <T> newestByKey(items: List<T>, key: (T) -> String, date: (T) -> Long): Map<String, Long> {
        val out = HashMap<String, Long>()
        for (item in items) {
            val k = key(item)
            val d = date(item)
            if ((out[k] ?: Long.MIN_VALUE) < d) out[k] = d
        }
        return out
    }

    /** Seconds: the earliest `uploaded` per lowercased sha256; missing hashes and zero/negative times skipped. */
    fun uploadedByHash(blobs: List<BlobDescriptor>): Map<String, Long> {
        val out = HashMap<String, Long>()
        for (blob in blobs) {
            val hash = blob.sha256?.lowercase()?.takeIf { it.isNotEmpty() } ?: continue
            val secs = blob.uploaded?.takeIf { it > 0 } ?: continue
            if ((out[hash] ?: Long.MAX_VALUE) > secs) out[hash] = secs
        }
        return out
    }

    /** The stored file for a blob: `<sha256>` or `<sha256>.<ext>`. */
    fun storedFile(sha256: String, dir: File): File? {
        File(dir, sha256).takeIf { it.isFile }?.let { return it }
        return dir.listFiles { f -> f.isFile && f.name.startsWith("$sha256.") }?.minByOrNull { it.name }
    }

    /**
     * Sets the blob's modified time to [dateSeconds]. Nothing happens with no
     * date, a date not after 1970 or in the future, no stored file, or a file
     * last written before [writtenSince] (ms): that one was already in the
     * vault, and this copy did not write it. True when stamped.
     */
    fun stamp(sha256: String, dir: File, dateSeconds: Long?, writtenSince: Long, now: Long = System.currentTimeMillis()): Boolean {
        val millis = dateSeconds?.takeIf { it > 0 }?.times(1000)?.takeIf { it <= now } ?: return false
        val file = storedFile(sha256.lowercase(), dir) ?: return false
        if (file.lastModified() < writtenSince) return false
        return file.setLastModified(millis)
    }
}

/**
 * Gives a blob this run just stored its real date on disk ([CopiedInDate]).
 * [writtenSince]: ms when the copy started; an older file was already here.
 */
internal fun BlossomService.stampCopiedIn(sha256: String, dateSeconds: Long?, writtenSince: Long) {
    if (dateSeconds == null) return
    val config = configStore.config.value
    val dir = config.relayDataDir?.let { File(it, config.blossomPath) } ?: return
    if (!CopiedInDate.stamp(sha256, dir, dateSeconds, writtenSince)) {
        Log.i(TAG, "Copied ${sha256.take(8)} kept its write time (no stored file, older file or future date)")
    }
}
