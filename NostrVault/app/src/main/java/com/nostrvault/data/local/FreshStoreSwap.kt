package com.nostrvault.data.local

import java.io.File
import java.io.FileOutputStream

/**
 * Start fresh for the credential store as one swap that can't lose both
 * stores. The old file is copied to [pending] first (temp file, synced, then
 * renamed, so [pending] is either whole or absent); only then is the live
 * store deleted and a fresh one opened. While [pending] exists the swap is
 * unfinished, and [recover] puts the old store back. It is retired only once
 * the fresh store has opened and taken a write.
 *
 * Before, the old store was deleted before the fresh one opened: a failed
 * open, or the app killed in between, left the person with neither
 * (Logen, 3.0.0 43).
 */
internal class FreshStoreSwap(
    private val live: File,
    /** Deletes the live store, and the copy the process cached of it. */
    private val deleteLive: () -> Unit,
) {
    val pending = File(live.parentFile, live.nameWithoutExtension + ".pending-old.xml")
    private val partial = File(live.parentFile, live.nameWithoutExtension + ".pending-old.tmp")

    /**
     * Runs the swap. [openFresh] opens the empty store and proves it takes a
     * write (throw or null = not done). Once it is in, the old store's copy
     * moves to [keepAs], out of the way of [recover], which would otherwise
     * put it back over the new one next launch; if it can't be moved, the
     * swap is undone. On any failure the old store is put back and null
     * returned.
     */
    fun <T> run(openFresh: () -> T?, keepAs: File): T? {
        recover()
        // The old store couldn't be put back: don't build over it.
        if (pending.exists()) return null
        if (live.exists()) {
            live.copyTo(partial, overwrite = true)
            FileOutputStream(partial, true).use { it.fd.sync() }
            if (!partial.renameTo(pending)) {
                partial.delete()
                return null
            }
        }
        val opened = try {
            deleteLive()
            openFresh()
        } catch (e: Exception) {
            null
        }
        if (opened == null) {
            recover()
            return null
        }
        if (!retire(keepAs)) {
            // [pending] is still there, so the next launch's [recover] would
            // put the old store back over keys added to the fresh one. Undo
            // now instead and report Start fresh as not done (Tron, 44).
            keepAs.delete()
            recover()
            return null
        }
        return opened
    }

    /** Moves [pending] to [keepAs]. False when [pending] is still on disk. */
    private fun retire(keepAs: File): Boolean {
        if (!pending.exists() || pending.renameTo(keepAs)) return true
        // Never drop [pending] without a whole copy at [keepAs].
        if (runCatching { pending.copyTo(keepAs, overwrite = true) }.isFailure) return false
        return pending.delete()
    }

    /**
     * A swap that didn't finish (failed, or the app was killed) is undone:
     * whatever fresh store it got as far as is dropped and the old one put
     * back. Runs before every open; a no-op when no swap is pending. If the
     * old store can't be renamed back, [pending] is left in place and the
     * caller must not open the (now empty) live slot.
     */
    fun recover(): Boolean {
        partial.delete()
        if (!pending.exists()) return false
        deleteLive()
        return pending.renameTo(live)
    }
}
