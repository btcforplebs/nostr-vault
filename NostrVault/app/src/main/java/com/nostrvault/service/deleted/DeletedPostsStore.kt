package com.nostrvault.service.deleted

import android.content.Context
import dagger.hilt.android.qualifiers.ApplicationContext
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.asStateFlow
import kotlinx.serialization.encodeToString
import kotlinx.serialization.json.Json
import java.io.File
import javax.inject.Inject
import javax.inject.Singleton

/**
 * Your deleted posts, kept on this device for 30 days so they can be
 * un-deleted. One JSON file per account (hex pubkey), so switching accounts
 * never shows or re-posts another account's posts. Port of iOS
 * `DeletedPostsStore.swift`.
 *
 * Only the device that pressed Delete holds a copy: other devices get the
 * kind 5 and drop the post without one.
 */
@Singleton
class DeletedPostsStore internal constructor(private val directory: File) {

    @Inject constructor(@ApplicationContext context: Context) : this(File(context.filesDir, "deleted-posts"))

    private val json = Json { ignoreUnknownKeys = true }
    private val lock = Any()

    /** Bumps on every change, so an open Recently Deleted screen reloads. */
    private val _changes = MutableStateFlow(0)
    val changes: StateFlow<Int> = _changes.asStateFlow()

    /**
     * The account's saved posts, most recently deleted first. Posts past the
     * 30 days are dropped here, and from disk.
     */
    fun posts(account: String, nowMs: Long = System.currentTimeMillis()): List<DeletedPost> = synchronized(lock) {
        val stored = read(account)
        val kept = unexpired(stored, nowMs)
        if (kept.size != stored.size) write(kept, account)
        kept
    }

    /** Saves a copy. A second delete of the same id replaces the first copy. */
    fun save(post: DeletedPost, nowMs: Long = System.currentTimeMillis()) {
        synchronized(lock) {
            val posts = listOf(post) + read(post.pubkey).filter { it.id != post.id }
            write(unexpired(posts, nowMs), post.pubkey)
        }
        _changes.value++
    }

    /** Drops a copy: after un-delete, or Delete forever. */
    fun remove(id: String, account: String) {
        synchronized(lock) {
            val posts = read(account)
            val kept = posts.filter { it.id != id }
            if (kept.size != posts.size) write(kept, account)
        }
        _changes.value++
    }

    private fun fileFor(account: String): File? {
        val hex = account.lowercase()
        if (hex.length != 64 || !hex.all { it in '0'..'9' || it in 'a'..'f' }) return null
        return File(directory, "$hex.json")
    }

    private fun read(account: String): List<DeletedPost> {
        val file = fileFor(account)?.takeIf { it.exists() } ?: return emptyList()
        return try {
            json.decodeFromString(file.readText())
        } catch (e: Exception) {
            emptyList()
        }
    }

    private fun write(posts: List<DeletedPost>, account: String) {
        val file = fileFor(account) ?: return
        if (posts.isEmpty()) {
            file.delete()
            return
        }
        directory.mkdirs()
        val tmp = File(directory, "${file.name}.tmp")
        tmp.writeText(json.encodeToString(posts))
        tmp.renameTo(file)
    }

    companion object {
        /** How long a deleted post stays un-deletable. */
        const val RETENTION_MS: Long = 30L * 24 * 60 * 60 * 1000

        /** Posts deleted less than [RETENTION_MS] ago, most recent first. */
        fun unexpired(posts: List<DeletedPost>, nowMs: Long): List<DeletedPost> =
            posts.filter { nowMs - it.deletedAt < RETENTION_MS }.sortedByDescending { it.deletedAt }
    }
}
