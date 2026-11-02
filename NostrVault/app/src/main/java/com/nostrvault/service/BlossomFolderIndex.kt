package com.nostrvault.service

import java.io.File

/**
 * Which files the vault's Blossom folder holds, by sha256, kept in memory so a photo that is not on the phone
 * costs one look at the folder's date instead of a dozen file checks. Port of iOS `BlossomFolderIndex`.
 *
 * The relay writes and deletes blobs itself, so the app is not told about every change. The folder's own
 * modification date moves whenever a file is added, renamed into place or removed, so the list is read again
 * when that date differs from the one it was read at. Some file systems keep that date to the second, so a
 * change in the same second as the last one would not move it: a list read within [SETTLE_MS] of the folder's
 * date is not trusted, and is read again next time. Memory only: nothing here is written anywhere.
 */
class BlossomFolderIndex(private val clock: () -> Long = System::currentTimeMillis) {
    private var directory: File? = null
    private var folderDate = 0L
    private var readAt = 0L
    private var byHash: Map<String, String> = emptyMap()

    /** How many times the folder was listed: for tests. */
    @Volatile var listings = 0
        private set

    /** The file named `<hash>.<ext>` in [dir] (never a `.corrupt` one), or null. */
    @Synchronized
    fun file(forHash: String, dir: File): File? {
        val date = dir.lastModified()
        val trusted = dir == directory && date != 0L && date == folderDate && readAt - folderDate > SETTLE_MS
        if (!trusted) reload(dir, date)
        return byHash[forHash]?.let { File(dir, it) }
    }

    /** Forget the list, so the next lookup reads the folder again. */
    @Synchronized
    fun invalidate() {
        directory = null
    }

    private fun reload(dir: File, date: Long) {
        listings++
        directory = dir
        // The date is taken before the listing, so a file landing while it runs moves the date past it.
        folderDate = date
        readAt = clock()
        val found = HashMap<String, String>()
        dir.list()?.forEach { name ->
            if (name.startsWith(".") || name.length < 66 || name[64] != '.' || name.endsWith(".corrupt")) return@forEach
            found.putIfAbsent(name.substring(0, 64), name)
        }
        byHash = found
    }

    companion object {
        /** A folder date this close to the listing may hide a change made in the same tick. */
        const val SETTLE_MS = 2_000L
    }
}
