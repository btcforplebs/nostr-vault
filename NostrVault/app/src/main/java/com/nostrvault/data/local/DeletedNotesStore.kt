package com.nostrvault.data.local

import android.content.Context
import java.io.File

/**
 * The ids of the posts each account has deleted, kept on disk so a relay
 * that still serves one cannot bring it back after a restart. Fed by your
 * own deletes here and by your kind-5 requests arriving from your other
 * devices. One file per account, next to `EngagementTracker`'s interaction
 * state, one id per line. Twin: iOS `DeletedNotesStore`.
 */
class DeletedNotesStore(private val dir: File) {
    private val lock = Any()
    private val loaded = HashMap<String, Set<String>>()

    fun ids(account: String): Set<String> = synchronized(lock) { idsLocked(account) }

    fun contains(id: String, account: String): Boolean = id in ids(account)

    /**
     * Adds [ids] for [account] and writes the file. Already-known ids are a
     * no-op, so a kind 5 echoed by several relays costs one write at most.
     */
    fun markDeleted(ids: Set<String>, account: String) {
        if (ids.isEmpty()) return
        synchronized(lock) {
            val current = idsLocked(account)
            val merged = current + ids
            if (merged.size == current.size) return
            loaded[account] = merged
            dir.mkdirs()
            val file = file(account)
            val tmp = File(dir, file.name + ".tmp")
            tmp.writeText(merged.sorted().joinToString("\n"))
            if (!tmp.renameTo(file)) file.writeText(merged.sorted().joinToString("\n"))
        }
    }

    fun file(account: String): File {
        val safeKey = account.ifEmpty { "owner" }.replace("/", "_")
        return File(dir, "deleted_notes_$safeKey.txt")
    }

    private fun idsLocked(account: String): Set<String> {
        loaded[account]?.let { return it }
        val file = file(account)
        val ids = if (file.exists()) {
            file.readLines().mapNotNullTo(HashSet()) { line -> line.trim().takeIf { it.isNotEmpty() } }
        } else {
            emptySet()
        }
        loaded[account] = ids
        return ids
    }

    companion object {
        lateinit var shared: DeletedNotesStore
            private set

        /** Called once from the Application, like the other context-bound stores. */
        fun init(context: Context) {
            shared = DeletedNotesStore(File(context.filesDir, "nostrvault_data"))
        }
    }
}
