package com.nostrvault.service

import java.io.File
import java.nio.file.Files

/**
 * Clears the app's own leftovers from its cache folder at start: upload and
 * compress copies a killed job left, and backup zips in `exports/` that were
 * shared and then kept (a media backup is as big as the vault). The iOS twin
 * is TempFileSweep.swift.
 *
 * Safety:
 * - Only the top of [cacheDir] and of `exports/` are looked at, and only
 *   names the app itself writes ([isOwn]). `media_cache`, `thumbnails`,
 *   `image_cache`, `video-cache` and every other folder are never touched.
 * - Symlinks are left alone.
 * - A file a running job holds ([isHeld]) is kept, however old.
 * - Only a file not changed for [MAX_AGE_MS] goes.
 */
object CacheSweep {
    const val MAX_AGE_MS = 24L * 60 * 60 * 1000
    const val EXPORTS = "exports"

    private val PREFIXES = listOf(
        "upload_", "profile_upload_", "clipboard_", "livechat_", "dm_lock_", "dm_upload_", "dm_video_",
        "divine_", "cover_", "listing_", "video_", "compressed_", "backup", "import-", "queued-",
    )

    data class Result(val removed: Int = 0, val removedBytes: Long = 0, val kept: Int = 0)

    fun isOwn(name: String): Boolean = PREFIXES.any { name.startsWith(it) }

    fun sweep(
        cacheDir: File,
        nowMs: Long = System.currentTimeMillis(),
        maxAgeMs: Long = MAX_AGE_MS,
        isHeld: (File) -> Boolean = { BlobStream.isLive(it) },
    ): Result {
        var r = Result()
        fun consider(f: File, own: Boolean) {
            if (!own || Files.isSymbolicLink(f.toPath()) || !f.isFile) return
            if (isHeld(f) || nowMs - f.lastModified() <= maxAgeMs) {
                r = r.copy(kept = r.kept + 1)
                return
            }
            val size = f.length()
            if (f.delete()) r = r.copy(removed = r.removed + 1, removedBytes = r.removedBytes + size)
        }
        cacheDir.listFiles()?.forEach { consider(it, isOwn(it.name)) }
        val exports = File(cacheDir, EXPORTS)
        if (!Files.isSymbolicLink(exports.toPath())) exports.listFiles()?.forEach { consider(it, true) }
        return r
    }

    /** Before a new export: the zips earlier ones handed to the share sheet. */
    fun clearExports(cacheDir: File, keep: File? = null) {
        File(cacheDir, EXPORTS).listFiles()?.forEach { f ->
            if (f.isFile && f != keep && !Files.isSymbolicLink(f.toPath())) f.delete()
        }
    }
}
