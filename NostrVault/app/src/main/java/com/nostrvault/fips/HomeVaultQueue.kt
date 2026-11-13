package com.nostrvault.fips

import kotlinx.serialization.Serializable
import kotlinx.serialization.encodeToString
import kotlinx.serialization.json.Json
import kotlinx.serialization.json.JsonArray
import kotlinx.serialization.json.contentOrNull
import kotlinx.serialization.json.intOrNull
import kotlinx.serialization.json.jsonObject
import kotlinx.serialization.json.jsonPrimitive
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
        /**
         * For [TYPE_BLOB]: sign only with this device's mesh key, never the owner's (a feed Mirror, #1920 follow-up).
         * Such an item needs no owner signer, so it is never held for one.
         */
        val meshKeyOnly: Boolean = false,
        /** For [TYPE_FILE_NOTE]: what to tell the vault's `/files` about one blob. Optional: older queues lack it. */
        val fileNote: FileNoteDraft? = null,
    )

    /**
     * The fileNote lane (RESEARCH/NV_MEDIA_LIVE_FILE_NOTES_PLAN.md gap 1): what to tell the home vault's `/files` about
     * one blob. The note is signed with this device's mesh key when it is sent, never when queued, so an unpair or a
     * new key in between never ships a stale signature. Apple's `FileNoteDraft`.
     */
    @Serializable
    data class FileNoteDraft(
        val action: String,
        val sha256: String,
        val mime: String,
        val size: Long,
        /** The media servers that have it (add only); empty = the vault holds it. */
        val servers: List<String> = emptyList(),
    ) {
        companion object {
            const val ADD = "add"
            const val DELETE = "delete"
        }
    }

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
        meshKeyOnly: Boolean = false,
        writeTo: (File) -> Unit,
    ): Boolean = synchronized(lock) {
        val current = load()
        if (current.any { it.key == sha256 }) return true
        if (countsTowardCap(current) >= maxItems) return false
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
        add(Item(key = sha256, type = TYPE_BLOB, contentType = contentType, queuedAt = now, meshKeyOnly = meshKeyOnly))
    }

    /**
     * Remember that [sha256] still has to reach a public server. No bytes:
     * it is pushed from this phone's own relay.
     */
    fun addPublicCopy(sha256: String, contentType: String, server: String, now: Long = System.currentTimeMillis()): Boolean =
        // Keyed by blob and server: the same blob published again after the
        // mirror order changed names a second server, and each needs its copy.
        add(Item(key = publicCopyKey(sha256, server), type = TYPE_PUBLIC_COPY, contentType = contentType, server = server, queuedAt = now))

    /**
     * Queue one blob's file note: one item per blob, the newest word winning (a delete takes back a waiting add, and
     * the other way). The same word twice is queued once. False when the queue is full.
     */
    fun addFileNote(draft: FileNoteDraft, now: Long = System.currentTimeMillis()): Boolean = synchronized(lock) {
        val sha = draft.sha256.lowercase()
        val key = fileNoteKey(sha)
        val current = load()
        val same = current.firstOrNull { it.key == key }
        if (same != null && same.fileNote?.action == draft.action) return true
        val rest = current.filterNot { it.key == key }
        // Notes have their own cap: each upload queues a blob and its note, so sharing one cap halved the blobs.
        if (rest.count { it.type == TYPE_FILE_NOTE } >= maxItems) return false
        save(rest + Item(key = key, type = TYPE_FILE_NOTE, contentType = draft.mime, queuedAt = now, fileNote = draft.copy(sha256 = sha)))
        true
    }

    fun blobFile(sha256: String): File = File(blobDir, sha256)

    fun update(item: Item) = synchronized(lock) {
        save(load().map { if (it.key == item.key) item else it })
    }

    /**
     * Drops what a signed delete takes back (device sync map §4.3): the queued events [eventIds] names, and
     * every send of blob [sha256] (the blob itself and its public copies). They are never sent. A file note stays:
     * the kind 5 for a deleted blob must still go. Returns how many items went.
     */
    fun dropDeleted(eventIds: Set<String> = emptySet(), sha256: String? = null): Int = synchronized(lock) {
        val all = load()
        val kept = all.filterNot { item ->
            (item.type == TYPE_EVENT && item.key in eventIds) ||
                (sha256 != null && item.type != TYPE_EVENT && item.type != TYPE_FILE_NOTE && (item.key == sha256 || item.key.startsWith("$sha256@")))
        }
        if (kept.size != all.size) {
            save(kept)
            if (sha256 != null) blobFile(sha256).delete()
        }
        all.size - kept.size
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
        if (countsTowardCap(current) >= maxItems) return false
        save(current + item)
        true
    }

    /** What [maxItems] counts for blobs, events and public copies: file notes are left out (Tron, PR 1990). */
    private fun countsTowardCap(items: List<Item>): Int = items.count { it.type != TYPE_FILE_NOTE }

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
        const val TYPE_FILE_NOTE = "file-note"

        /** A file note's key: apart from the blob's own item (keyed by the bare hash), which [add] would take it for. */
        fun fileNoteKey(sha256: String) = "${sha256.lowercase()}#note"

        fun publicCopyKey(sha256: String, server: String) = "$sha256@$server"

        /** The event ids a signed delete (kind 5) names with `e` tags; empty for anything else. */
        fun deletedEventIds(eventJson: String): Set<String> {
            val ev = try {
                Json.parseToJsonElement(eventJson).jsonObject
            } catch (e: Exception) {
                return emptySet()
            }
            if (ev["kind"]?.jsonPrimitive?.intOrNull != 5) return emptySet()
            val tags = (ev["tags"] as? JsonArray) ?: return emptySet()
            return tags.mapNotNull { tag ->
                val t = tag as? JsonArray ?: return@mapNotNull null
                if (t.size >= 2 && t[0].jsonPrimitive.contentOrNull == "e") t[1].jsonPrimitive.contentOrNull else null
            }.toSet()
        }

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
     * The 10063 a phone publishes: it merges, never replaces. [newest] is the newest signed list (any device's);
     * [managed] the servers this phone manages, which replace every non-mesh entry. Every `fipsmesh://` entry is
     * kept, in order, after the public servers (NIP-F1: BUD-03 clients try servers in order), except the ones the
     * owner took off on Media Servers ([dropMesh]); the ones they added there ([addMesh]) go after them. Nothing is
     * added or dropped for a vault linked or removed in My Devices (Logen 2026-11-08).
     */
    fun mergeServerList(
        newest: List<String>,
        managed: List<String>,
        addMesh: List<String> = emptyList(),
        dropMesh: Collection<String> = emptyList(),
    ): List<String>? {
        val drop = dropMesh.toSet()
        val mesh = newest.filter { val n = FipsMediaRouter.meshNpubIn(it); n != null && n !in drop } +
            addMesh.filter { it !in drop }.map { "fipsmesh://$it/" }
        val out = (managed.filter { FipsMediaRouter.meshNpubIn(it) == null } + mesh).distinct()
        // NIP-F1: never a list only the mesh or this home network can open. It reaches no outside reader
        // and would publish a home address (iOS #999, Tod: a real public server, not just reachable).
        return out.takeIf { it.any(::isPublicServer) }
    }

    /** The mesh [npubs] a 10063's [servers] does not list as `fipsmesh://<npub>/`. */
    fun unlisted(servers: List<String>, npubs: List<String>): List<String> {
        val listed = servers.mapNotNull { FipsMediaRouter.meshNpubIn(it) }.toSet()
        return npubs.filter { it !in listed }
    }

    /**
     * A server any reader can open: https, not a `.fips` mesh name, not a home network or Tailscale
     * host. iOS HomeVaultLogic.isPublicServer, plus its isReachableWithoutMesh host checks.
     */
    fun isPublicServer(url: String): Boolean {
        val uri = try { java.net.URI(url.trim()) } catch (_: Exception) { return false }
        if (!uri.scheme.equals("https", ignoreCase = true)) return false
        val host = uri.host?.lowercase()?.trimEnd('.')?.takeIf { it.isNotEmpty() } ?: return false
        if (host == "fips" || host.endsWith(".fips")) return false
        return !com.nostrvault.relay.DMInbox.isPrivateNetworkHost(host)
    }

    /**
     * A kiosk's mesh address as pasted or scanned: `npub1…`, `nostr:npub1…`
     * or `fipsmesh://npub1…/`. Null for anything else.
     */
    fun meshNpubFromInput(input: String): String? {
        var text = input.trim()
        if (text.startsWith("nostr:", ignoreCase = true)) text = text.drop(6)
        if (!text.startsWith("fipsmesh://")) text = "fipsmesh://$text/"
        if (!text.endsWith("/")) text += "/"
        return FipsMediaRouter.meshNpubIn(text)
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

    /**
     * A lane to another device of the owner's (a Mac, a phone) waits at most this long between tries: that device is
     * in reach only while its app is open, so a long wait misses it (Logen 2026-11-13). The mobile vault is always on
     * and keeps the long backoff.
     */
    const val LANE_BACKOFF_CAP_MS = 2 * 60_000L

    /** Whether sends to a device in [role] go on a lane (anything but the mobile vault). */
    fun isLane(role: DeviceRole): Boolean = role != DeviceRole.HOME_VAULT

    fun backoffMs(attempts: Int, lane: Boolean): Long =
        if (lane) backoffMs(attempts).coerceAtMost(LANE_BACKOFF_CAP_MS) else backoffMs(attempts)

    /** A lane tries every 2 minutes, so its try count says nothing: only age gives up on it. */
    fun expired(item: HomeVaultQueue.Item, now: Long, lane: Boolean): Boolean =
        if (lane) item.attempts > 0 && now - item.queuedAt > MAX_AGE_MS else expired(item, now)

    /** Npubs connected now that were not at the last look. */
    fun newlyInReach(now: Set<String>, before: Set<String>): Set<String> = now - before

    /** The items of a lane whose device just came into reach, made due now. Tries are kept. */
    fun wokenOnReach(items: List<HomeVaultQueue.Item>): List<HomeVaultQueue.Item> =
        items.filter { it.nextAt > 0 }.map { it.copy(nextAt = 0) }

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

    /**
     * Whether a send over the mesh waits for the owner's signer. Never: a blob signs with this device's mesh key, and
     * falls back to the owner's form only with a local key ([meshKeyOnly]), so a bunker or Amber is never asked and
     * nothing waits for a tap. Events are already signed; a file note signs with the mesh key.
     */
    @Suppress("UNUSED_PARAMETER")
    fun needsOwnerSignature(item: HomeVaultQueue.Item): Boolean = false

    /** Whether a blob over the mesh signs with the mesh key only: a feed Mirror always, anything with a remote signer. */
    fun meshKeyOnly(item: HomeVaultQueue.Item, localSigner: Boolean): Boolean = item.meshKeyOnly || !localSigner

    const val MAX_AGE_MS = 14L * 24 * 60 * 60_000L
    const val MAX_ATTEMPTS = 40

    /** An HTTP status for a Blossom PUT /upload. */
    fun uploadOutcome(code: Int): HomeVaultSend = when (code) {
        in 200..299 -> HomeVaultSend.SENT
        // Not the owner's key, no length, or too large: sending again changes nothing.
        // 400 is not here: the door answers it for a body cut mid-transfer, and a
        // kiosk build whose port spoke TLS answered it to every upload (iOS #1135);
        // both are about this try, not the blob (iOS HomeVaultLogic.uploadResult).
        401, 403, 411, 413, 415 -> HomeVaultSend.REJECTED
        // 404/405 included: a vault on older code has no upload door on the
        // mesh yet, and keeps what waits until it does.
        else -> HomeVaultSend.RETRY
    }
}
