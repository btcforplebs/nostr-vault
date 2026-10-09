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
class HomeVaultQueue(private val dir: File) {

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
    )

    private val json = Json { ignoreUnknownKeys = true; encodeDefaults = true }
    private val listFile get() = File(dir, "queue.json")
    private val blobDir get() = File(dir, "blobs")
    private val lock = Any()

    fun items(): List<Item> = synchronized(lock) { load() }

    val size: Int get() = items().size

    fun addEvent(eventId: String, eventJson: String, now: Long = System.currentTimeMillis()): Boolean =
        add(Item(key = eventId, type = TYPE_EVENT, eventJson = eventJson, queuedAt = now))

    /**
     * Queue a blob, taking a copy of it from [writeTo]. False, and nothing
     * queued, when the copy fails — a queue entry without its bytes could
     * never be sent.
     */
    fun addBlob(
        sha256: String,
        contentType: String,
        now: Long = System.currentTimeMillis(),
        writeTo: (File) -> Unit,
    ): Boolean = synchronized(lock) {
        if (load().any { it.key == sha256 }) return true
        blobDir.mkdirs()
        val file = blobFile(sha256)
        val temp = File(blobDir, "$sha256.part")
        try {
            writeTo(temp)
            if (!temp.renameTo(file)) return false
        } catch (_: Exception) {
            temp.delete()
            return false
        }
        add(Item(key = sha256, type = TYPE_BLOB, contentType = contentType, queuedAt = now))
    }

    fun blobFile(sha256: String): File = File(blobDir, sha256)

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
        save(current + item)
        true
    }

    private fun load(): List<Item> = try {
        if (listFile.exists()) json.decodeFromString(listFile.readText()) else emptyList()
    } catch (_: Exception) {
        emptyList()
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
        // NIP-01 prefixes. A duplicate is already there; rate limits and
        // relay errors pass; anything else (blocked, invalid, restricted) is final.
        message.startsWith("duplicate:") -> HomeVaultSend.SENT
        message.startsWith("rate-limited:") || message.startsWith("error:") -> HomeVaultSend.RETRY
        else -> HomeVaultSend.REJECTED
    }

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
