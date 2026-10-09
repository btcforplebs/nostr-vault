package com.nostrvault.fips

import kotlinx.serialization.Serializable
import kotlinx.serialization.encodeToString
import kotlinx.serialization.json.Json
import java.io.File

/**
 * What waits to reach the home vault, on disk so it survives a restart.
 *
 * Plain files, no database: one JSON list, rewritten whole on each change
 * (the queue is short — it drains whenever the vault is reachable), and one
 * file per waiting blob, named by its sha256. A blob is copied in rather than
 * read back from wherever it came from, so the item can be sent even if the
 * phone's own relay lost or never got it.
 */
class HomeVaultQueue(
    private val dir: File,
    private val maxItems: Int = MAX_ITEMS,
    private val maxBlobBytes: Long = MAX_BLOB_BYTES,
) {

    @Serializable
    data class Item(
        /** Event id, or blob sha256: the same thing queued twice is one item. */
        val key: String,
        val type: String,
        /** Signed event JSON, for [TYPE_EVENT]. */
        val eventJson: String? = null,
        /** MIME type, for [TYPE_BLOB]. */
        val contentType: String? = null,
        val queuedAt: Long = 0,
        /** Sends that came back RETRY so far. */
        val attempts: Int = 0,
        /** Not tried again before this time (backoff). */
        val nextAt: Long = 0,
    )

    private val json = Json { ignoreUnknownKeys = true; encodeDefaults = true }
    private val listFile get() = File(dir, "queue.json")
    private val blobDir get() = File(dir, "blobs")
    private val lock = Any()

    init {
        sweepOrphans()
    }

    fun items(): List<Item> = synchronized(lock) { load() }

    val size: Int get() = items().size

    /** Bytes held in waiting blobs. */
    fun blobBytes(): Long = blobDir.listFiles()?.sumOf { it.length() } ?: 0L

    fun addEvent(eventId: String, eventJson: String, now: Long = System.currentTimeMillis()): Boolean =
        add(Item(key = eventId, type = TYPE_EVENT, eventJson = eventJson, queuedAt = now))

    /**
     * Queue a blob, taking a copy of it from [writeTo]. False, and nothing
     * queued, when the copy fails or the queue is full — a queue entry
     * without its bytes could never be sent, and a full one is not allowed
     * to eat the phone's storage.
     */
    fun addBlob(
        sha256: String,
        contentType: String,
        now: Long = System.currentTimeMillis(),
        writeTo: (File) -> Unit,
    ): Boolean = synchronized(lock) {
        val current = load()
        if (current.any { it.key == sha256 }) return true
        if (current.size >= maxItems) return false
        blobDir.mkdirs()
        val file = blobFile(sha256)
        val temp = File(blobDir, "$sha256.part")
        try {
            writeTo(temp)
            if (blobBytes() > maxBlobBytes || !temp.renameTo(file)) {
                temp.delete()
                return false
            }
        } catch (_: Exception) {
            temp.delete()
            return false
        }
        add(Item(key = sha256, type = TYPE_BLOB, contentType = contentType, queuedAt = now))
    }

    fun blobFile(sha256: String): File = File(blobDir, sha256)

    fun update(item: Item) = synchronized(lock) {
        save(load().map { if (it.key == item.key) item else it })
    }

    fun remove(key: String) = synchronized(lock) {
        save(load().filterNot { it.key == key })
        blobFile(key).delete()
    }

    fun clear() = synchronized(lock) {
        save(emptyList())
        blobDir.deleteRecursively()
    }

    private fun add(item: Item): Boolean = synchronized(lock) {
        val current = load()
        if (current.any { it.key == item.key }) return true
        if (current.size >= maxItems) return false
        save(current + item)
        true
    }

    private fun load(): List<Item> {
        if (!listFile.exists()) return emptyList()
        return try {
            json.decodeFromString(listFile.readText())
        } catch (_: Exception) {
            // Kept aside, not overwritten by the next save; its blobs go with
            // the orphan sweep rather than sitting on disk forever.
            listFile.renameTo(File(dir, "queue.json.corrupt"))
            sweepOrphans(known = emptySet())
            emptyList()
        }
    }

    /** Delete blob files no item names (a crash between copy and save, a lost list). */
    private fun sweepOrphans(known: Set<String>? = null) = synchronized(lock) {
        val keys = known ?: load().map { it.key }.toSet()
        blobDir.listFiles()?.forEach { if (it.name !in keys) it.delete() }
    }

    private fun save(items: List<Item>) {
        dir.mkdirs()
        // Write then rename, so a crash mid-write cannot empty the queue.
        val temp = File(dir, "queue.json.part")
        temp.writeText(json.encodeToString(items))
        temp.renameTo(listFile)
    }

    companion object {
        const val TYPE_EVENT = "event"
        const val TYPE_BLOB = "blob"
        const val MAX_ITEMS = 500
        const val MAX_BLOB_BYTES = 1L * 1024 * 1024 * 1024
    }
}

/** How one send to the home vault ended. */
enum class HomeVaultSend {
    /** The vault has it (or already had it): drop it from the queue. */
    SENT,

    /** The vault said no for good (not the owner, too big): drop it, retrying won't help. */
    REJECTED,

    /** Not reachable, or a passing refusal: keep it and try again later. */
    RETRY,
}

/** The pure decisions [HomeVaultSender] makes, kept apart so they can be tested. */
object HomeVaultRules {
    /**
     * The owner's own mesh vaults this phone can send to: the `fipsmesh://`
     * entries in the owner's 10063, minus this phone's own address.
     */
    /**
     * The 10063 a phone publishes: it merges, never replaces. [newest] is the
     * newest signed list (any device's); [managed] the servers this phone
     * manages, which replace every non-mesh entry. Every `fipsmesh://` entry
     * is kept, in order, since other devices put those there; the home
     * vault's goes first.
     */
    fun mergeServerList(newest: List<String>, managed: List<String>, homeVaultNpub: String?): List<String> {
        val mesh = newest.filter { FipsMediaRouter.meshNpubIn(it) != null }.distinct()
        val home = mesh.filter { homeVaultNpub != null && FipsMediaRouter.meshNpubIn(it) == homeVaultNpub }
        return (home + managed.filter { FipsMediaRouter.meshNpubIn(it) == null } + (mesh - home.toSet())).distinct()
    }

    fun candidates(ownerServerList: List<String>, ownMeshNpub: String?): List<String> =
        ownerServerList.mapNotNull { FipsMediaRouter.meshNpubIn(it) }
            .filter { it != ownMeshNpub }
            .distinct()

    /** A relay's `OK` for an event: accepted, a duplicate, or why not. */
    fun eventOutcome(accepted: Boolean, message: String): HomeVaultSend = when {
        accepted -> HomeVaultSend.SENT
        // NIP-01 prefixes. A duplicate is already there. Rate limits and
        // relay errors pass, and so may auth: this sender has no NIP-42, so a
        // door that starts asking must not make every post vanish. Anything
        // else (blocked, invalid, pow) is final.
        message.startsWith("duplicate:") -> HomeVaultSend.SENT
        RETRY_PREFIXES.any { message.startsWith(it) } -> HomeVaultSend.RETRY
        else -> HomeVaultSend.REJECTED
    }

    private val RETRY_PREFIXES = listOf("rate-limited:", "error:", "auth-required:", "restricted:")

    /** Wait before the next try after [attempts] RETRYs: 1 min doubling, at most 6 h. */
    fun backoffMs(attempts: Int): Long =
        (60_000L shl (attempts - 1).coerceIn(0, 9)).coerceAtMost(6 * 60 * 60_000L)

    /** Dropped instead of tried again: too old, or retried too often. */
    fun expired(item: HomeVaultQueue.Item, now: Long): Boolean =
        now - item.queuedAt > MAX_AGE_MS || item.attempts >= MAX_ATTEMPTS

    const val MAX_AGE_MS = 14L * 24 * 60 * 60_000L
    const val MAX_ATTEMPTS = 40

    /** An HTTP status for a Blossom PUT /upload. */
    fun uploadOutcome(code: Int): HomeVaultSend = when (code) {
        in 200..299 -> HomeVaultSend.SENT
        // Not the owner's key, malformed, or too large: sending again changes nothing.
        400, 401, 403, 411, 413, 415 -> HomeVaultSend.REJECTED
        // 404/405 included: a vault on older code has no upload door on the
        // mesh yet, and keeps what waits until it does.
        else -> HomeVaultSend.RETRY
    }
}
