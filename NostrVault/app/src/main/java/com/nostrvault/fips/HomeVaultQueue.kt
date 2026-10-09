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
        /** For [TYPE_PUBLIC_COPY]: the server the published note names. Only it counts. */
        val server: String? = null,
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
        /** The blob's size, checked before copying so an oversized one is never written. */
        byteCount: Long,
        now: Long = System.currentTimeMillis(),
        writeTo: (File) -> Unit,
    ): Boolean = synchronized(lock) {
        val current = load()
        if (current.any { it.key == sha256 }) return true
        if (current.size >= maxItems) return false
        if (blobBytes() + byteCount > maxBlobBytes) return false
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

    /**
     * Remember that [sha256] still has to reach a public server. No bytes:
     * it is pushed from this phone's own relay.
     */
    fun addPublicCopy(sha256: String, contentType: String, server: String, now: Long = System.currentTimeMillis()): Boolean =
        // Keyed by blob and server: the same blob published again after the
        // mirror order changed names a second server, and each needs its copy.
        add(Item(key = publicCopyKey(sha256, server), type = TYPE_PUBLIC_COPY, contentType = contentType, server = server, queuedAt = now))

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
        const val TYPE_PUBLIC_COPY = "public-copy"

        fun publicCopyKey(sha256: String, server: String) = "$sha256@$server"

        /** The blob a key names: a public copy's key is `<sha256>@<server>`. */
        fun shaOf(key: String) = key.substringBefore('@')
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
     * is kept, in order, since other devices put those there, and they go
     * after the public servers (NIP-F1): BUD-03 clients try servers in order.
     * The home vault is the setting, not a list position.
     */
    fun mergeServerList(newest: List<String>, managed: List<String>): List<String> {
        val mesh = newest.filter { FipsMediaRouter.meshNpubIn(it) != null }
        return (managed.filter { FipsMediaRouter.meshNpubIn(it) == null } + mesh).distinct()
    }

    /**
     * The server a note's URL names when only the home vault has the blob
     * yet: the first public `https` one. Mesh readers fetch the hash from
     * the home vault meanwhile (NIP-F1), everyone else once the public copy
     * lands. Null when there is none, so the post waits as before.
     */
    fun publicServerFor(mirrors: List<String>, isPrivate: (String) -> Boolean): String? =
        mirrors.firstOrNull { it.startsWith("https://") && !isPrivate(it) }?.trimEnd('/')

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
        // else is final, including restricted: (the door's answer to a key
        // that isn't the owner's).
        message.startsWith("duplicate:") -> HomeVaultSend.SENT
        RETRY_PREFIXES.any { message.startsWith(it) } -> HomeVaultSend.RETRY
        else -> HomeVaultSend.REJECTED
    }

    private val RETRY_PREFIXES = listOf("rate-limited:", "error:", "auth-required:")

    /** Wait before the next try after [attempts] RETRYs: 1 min doubling, at most 6 h. */
    fun backoffMs(attempts: Int): Long =
        (60_000L shl (attempts - 1).coerceIn(0, 9)).coerceAtMost(6 * 60 * 60_000L)

    /** Dropped instead of tried again: too old, or retried too often. */
    /**
     * The age limit only applies once an item has been tried: it reads the
     * wall clock, and a clock jumped forward (or a date set by hand) must
     * not silently empty a queue that never got a chance to send.
     */
    fun expired(item: HomeVaultQueue.Item, now: Long): Boolean =
        item.attempts >= MAX_ATTEMPTS || (item.attempts > 0 && now - item.queuedAt > MAX_AGE_MS)

    /** External-signer prompts one Send now may cause. */
    const val PROMPTS_PER_TAP = 10

    /** What one pass tries, and whether anything was held back for the signer. */
    data class Selection(val toTry: List<HomeVaultQueue.Item>, val heldForSigner: Boolean)

    /**
     * The items a pass tries, oldest first. A background pass takes only
     * what is due and nothing that needs a signature from a signer that is
     * not a local key (each would be a prompt). Send now ([userInitiated])
     * ignores backoff and may prompt, at most [promptCap] times.
     */
    fun select(
        items: List<HomeVaultQueue.Item>,
        now: Long,
        userInitiated: Boolean,
        localSigner: Boolean,
        needsSignature: (HomeVaultQueue.Item) -> Boolean,
        promptCap: Int = PROMPTS_PER_TAP,
    ): Selection {
        val toTry = mutableListOf<HomeVaultQueue.Item>()
        var prompts = 0
        var held = false
        for (item in items) {
            if (!userInitiated && item.nextAt > now) continue
            if (!localSigner && needsSignature(item)) {
                if (!userInitiated || prompts >= promptCap) {
                    held = true
                    continue
                }
                prompts++
            }
            toTry += item
        }
        return Selection(toTry, held)
    }

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
