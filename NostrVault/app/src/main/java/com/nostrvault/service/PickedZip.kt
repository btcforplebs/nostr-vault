package com.nostrvault.service

import kotlinx.coroutines.CoroutineDispatcher
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.NonCancellable
import kotlinx.coroutines.withContext
import java.io.File
import java.io.InputStream

/**
 * A backup zip the person picked, copied into the cache so the engine can read it by path (audit #17): the copy
 * runs off the main thread (a GB file on the main thread is an ANR), a failed copy is an error rather than a crash,
 * and the copy is gone once the restore is done, whatever it returned. A copy a kill left behind goes on the next
 * app start ([sweep]).
 */
object PickedZip {
    private const val PREFIX = "picked-"

    /**
     * [open]'s bytes into a fresh cache file, then [use] on it; the file is deleted after. Null [open] (the picker's
     * file is gone) or a failed copy throws [java.io.IOException] with a plain message, never a crash on the caller's
     * thread.
     */
    suspend fun <T> use(
        cacheDir: File,
        open: () -> InputStream?,
        io: CoroutineDispatcher = Dispatchers.IO,
        use: suspend (File) -> T,
    ): T {
        val file = withContext(io) {
            cacheDir.mkdirs()
            File.createTempFile(PREFIX, ".zip", cacheDir)
        }
        try {
            withContext(io) {
                val input = runCatching(open).getOrNull() ?: throw java.io.IOException("Could not open the backup file")
                input.use { i -> file.outputStream().use { i.copyTo(it) } }
            }
            return use(file)
        } finally {
            // NonCancellable: a closed screen still leaves no copy behind.
            withContext(NonCancellable + io) { file.delete() }
        }
    }

    /** Copies earlier runs left behind (a kill mid-restore), and the old fixed names setup used. */
    fun sweep(cacheDir: File) {
        cacheDir.listFiles()?.forEach { f ->
            if ((f.name.startsWith(PREFIX) && f.name.endsWith(".zip")) || f.name in OLD_NAMES) f.delete()
        }
    }

    private val OLD_NAMES = setOf("restore_backup.zip", "media_import.zip")
}
