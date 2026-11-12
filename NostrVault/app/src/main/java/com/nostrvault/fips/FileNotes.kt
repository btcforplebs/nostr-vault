package com.nostrvault.fips

import kotlinx.serialization.json.JsonArray
import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.JsonPrimitive
import kotlinx.serialization.json.buildJsonArray
import kotlinx.serialization.json.buildJsonObject
import kotlinx.serialization.json.contentOrNull
import kotlinx.serialization.json.doubleOrNull
import kotlinx.serialization.json.intOrNull
import kotlinx.serialization.json.longOrNull
import kotlinx.serialization.json.put

/**
 * NIP-94 file notes (kind 1063) on the home vault's `/files` room (RESEARCH/NV_MEDIA_LIVE_FILE_NOTES_PLAN.md §1-§2,
 * haven-go files_relay.go). One note per (signing device, blob), signed with this device's mesh key only
 * ([MeshKeySigner.fileNotes]), never the account key or its signer (Logen, 2026-11-05). Pure, branch for branch with
 * Apple's `FileNote.swift` (Tara, NIP-94 step 2).
 */
data class FileNote(
    val id: String,
    /** The device mesh key (or the vault's own key) that signed it. */
    val signer: String,
    val createdAt: Long,
    val sha256: String,
    val mime: String,
    val size: Long,
    /** Whose media this is (one `p`, the vault owner). */
    val owner: String,
    /** `url` then each `fallback`, https only. */
    val urls: List<String>,
) {
    enum class TileState { VISIBLE, DIMMED, HIDDEN }

    companion object {
        const val KIND = 1063
        const val DELETION_KIND = 5
        const val AUTH_KIND = 22242

        /**
         * The tags of a device's note for one blob, or null when the blob, type, size or owner would make the vault
         * refuse it. [servers]: the media servers that have it; mesh and home-network ones are left out (the note
         * never names a place only this home can open), and none at all means the vault itself holds it.
         */
        fun tags(sha256: String, mime: String, size: Long, owner: String, servers: List<String>): List<List<String>>? {
            val x = sha256.lowercase()
            val m = mime.trim()
            if (!isHex64(x) || m.isEmpty() || size < 0 || !isHex64(owner)) return null
            val tags = mutableListOf(listOf("x", x), listOf("m", m), listOf("size", size.toString()), listOf("p", owner))
            val links = servers.mapNotNull { publicBlobUrl(it, x, m) }.distinct()
            links.forEachIndexed { i, link -> tags += listOf(if (i == 0) "url" else "fallback", link) }
            tags += listOf("client", "nostr-vault")
            return tags
        }

        /** A note as the vault serves it, or null for anything it should never have taken (a reader does not trust the room blindly). */
        fun parse(event: JsonObject): FileNote? {
            if (event.int("kind") != KIND) return null
            val id = event.string("id")?.takeIf { it.isNotEmpty() } ?: return null
            val signer = event.string("pubkey")?.takeIf { it.isNotEmpty() } ?: return null
            val t = StringTags.of(event) ?: return null
            val x = t.first("x")?.takeIf(::isHex64) ?: return null
            val m = t.first("m")?.takeIf { it.isNotEmpty() } ?: return null
            val size = t.first("size")?.toLongOrNull()?.takeIf { it >= 0 } ?: return null
            val ps = t.all("p")
            if (ps.size != 1 || !isHex64(ps[0])) return null
            val urls = (t.all("url") + t.all("fallback")).filter { it.lowercase().startsWith("https://") && isUrl(it) }
            return FileNote(id, signer, createdAt(event), x, m, size, ps[0], urls)
        }

        /** The live REQ every open Media tab keeps on `/files`. */
        fun liveFilter(owner: String, since: Long?): JsonObject = buildJsonObject {
            put("kinds", buildJsonArray { add(JsonPrimitive(KIND)); add(JsonPrimitive(DELETION_KIND)) })
            put("#p", buildJsonArray { add(JsonPrimitive(owner)) })
            if (since != null) put("since", since)
        }

        /** The websocket for `/files` on a vault: the mesh ingress base keeps its token path; a vault's own relay address gets `/files`. */
        fun filesUrl(base: String): String? {
            val uri = runCatching { java.net.URI(base) }.getOrNull() ?: return null
            if (uri.host == null) return null
            val scheme = when (uri.scheme?.lowercase()) {
                "https", "wss" -> "wss"
                else -> "ws"
            }
            val path = (uri.rawPath ?: "").trimEnd('/') + "/files"
            val port = if (uri.port >= 0) ":${uri.port}" else ""
            val query = uri.rawQuery?.let { "?$it" } ?: ""
            return "$scheme://${uri.host}$port$path$query"
        }

        /**
         * The `relay` tag of the NIP-42 AUTH. Over the mesh the vault pins it to its own mesh address (haven-go
         * meshAuthURL); on the vault's own relay it is the address dialled.
         */
        fun authRelayUrl(vaultNpub: String?, connected: String): String =
            if (!vaultNpub.isNullOrEmpty()) "ws://$vaultNpub.fips/files" else connected

        fun authTags(relayUrl: String, challenge: String): List<List<String>> =
            listOf(listOf("relay", relayUrl), listOf("challenge", challenge))

        // Tile check (plan gap 3)

        /**
         * A note-only tile (not in this device's folder). [serverStatuses]: the HEAD answer of each server the notes
         * name (null = no answer). [vaultHas]: the home vault's answer, null when not asked or no answer. It hides
         * only when every server said 404 and the vault lacks it: a server that didn't answer is not proof the file
         * is gone.
         */
        fun tileState(serverStatuses: List<Int?>, vaultHas: Boolean?): TileState {
            if (vaultHas == true || serverStatuses.any { it != null && it in 200..299 }) return TileState.VISIBLE
            if (vaultHas == false && serverStatuses.all { it == 404 }) return TileState.HIDDEN
            return TileState.DIMMED
        }

        fun isHex64(s: String): Boolean = s.length == 64 && s.all { it in '0'..'9' || it in 'a'..'f' }

        fun createdAt(event: JsonObject): Long {
            val p = event["created_at"] as? JsonPrimitive ?: return 0
            return p.longOrNull ?: p.doubleOrNull?.toLong() ?: 0
        }

        /**
         * A blob's public link on [server], or null when the server is not public ([HomeVaultRules.isPublicServer]).
         * Apple's `HomeVaultLogic.publicBlobURL`: the same extensions, so both platforms name the same link.
         */
        fun publicBlobUrl(server: String, sha256: String, contentType: String): String? {
            if (!HomeVaultRules.isPublicServer(server)) return null
            val ext = when (contentType.lowercase()) {
                "image/jpeg", "image/jpg" -> ".jpg"
                "image/png" -> ".png"
                "image/gif" -> ".gif"
                "image/webp" -> ".webp"
                "image/heic" -> ".heic"
                "video/mp4" -> ".mp4"
                "video/quicktime" -> ".mov"
                "video/webm" -> ".webm"
                "audio/mpeg" -> ".mp3"
                else -> ""
            }
            return "${server.trimEnd('/')}/$sha256$ext".takeIf(::isUrl)
        }

        private fun isUrl(s: String): Boolean = runCatching { java.net.URI(s).host != null }.getOrDefault(false)
    }
}

/** A kind 5 on `/files`: it names the notes it deletes, says `k` 1063, and the hash it is about. */
data class FileNoteDeletion(
    val id: String,
    val signer: String,
    val createdAt: Long,
    val noteIds: Set<String>,
    val hashes: Set<String>,
) {
    companion object {
        /** Tags for deleting every note [noteIds] (from a REQ `#x` on `/files`) for one blob; null with no note to name (the vault would refuse it). */
        fun tags(noteIds: List<String>, sha256: String, owner: String): List<List<String>>? {
            val ids = noteIds.filter { it.isNotEmpty() }.toSortedSet().toList()
            val x = sha256.lowercase()
            if (ids.isEmpty() || !FileNote.isHex64(x) || !FileNote.isHex64(owner)) return null
            return ids.map { listOf("e", it) } + listOf(listOf("k", FileNote.KIND.toString()), listOf("x", x), listOf("p", owner))
        }

        fun parse(event: JsonObject): FileNoteDeletion? {
            if (event.int("kind") != FileNote.DELETION_KIND) return null
            val id = event.string("id")?.takeIf { it.isNotEmpty() } ?: return null
            val signer = event.string("pubkey") ?: return null
            val t = StringTags.of(event) ?: return null
            if (FileNote.KIND.toString() !in t.all("k")) return null
            val ids = t.all("e").toSet()
            if (ids.isEmpty()) return null
            return FileNoteDeletion(id, signer, FileNote.createdAt(event), ids, t.all("x").filter(FileNote::isHex64).toSet())
        }
    }
}

/** One Media tab tile from the notes: a hash some live note names. */
data class FileNoteTile(
    val sha256: String,
    val mime: String,
    val size: Long,
    /** The newest note's time. */
    val createdAt: Long,
    /** Every live note's links, newest note first, each once. */
    val urls: List<String>,
)

/**
 * What the live notes say, merged by hash. Deletions are kept so a note replayed after its deletion never comes back.
 * Not thread-safe: one owner applies events in order (Apple's struct, mutated in place).
 */
class FileNotesState(
    /** Only this owner's notes count; null takes the room's word. */
    var owner: String? = null,
) {
    sealed class Change {
        data object None : Change()
        data class Added(val sha256: String) : Change()
        data class Removed(val sha256: String) : Change()
    }

    private val notes = HashMap<String, FileNote>()
    private val deleted = HashSet<String>()

    @Volatile
    var newestSeen: Long? = null
        private set

    /** Apply one event from the room: what that does to the tiles. */
    fun apply(event: JsonObject): Change {
        val at = FileNote.createdAt(event)
        FileNote.parse(event)?.let { note ->
            if (owner != null && owner != note.owner) return Change.None
            seen(at)
            if (note.id in deleted || notes.containsKey(note.id)) return Change.None
            val had = hasLiveNote(note.sha256)
            notes[note.id] = note
            return if (had) Change.None else Change.Added(note.sha256)
        }
        FileNoteDeletion.parse(event)?.let { deletion ->
            seen(at)
            val touched = sortedSetOf<String>()
            for (id in deletion.noteIds) {
                deleted += id
                notes.remove(id)?.let { touched += it.sha256 }
            }
            // One hash per deletion here (the vault's and the apps' form).
            touched.firstOrNull { !hasLiveNote(it) }?.let { return Change.Removed(it) }
        }
        return Change.None
    }

    /** Since when to ask again after a drop: the newest seen, less the overlap. */
    val since: Long? get() = newestSeen?.let { maxOf(0, it - RESUBSCRIBE_OVERLAP) }

    fun hasLiveNote(sha256: String): Boolean = notes.values.any { it.sha256 == sha256 }

    fun noteIds(sha256: String): List<String> = notes.values.filter { it.sha256 == sha256 }.map { it.id }.sorted()

    /** One tile per hash, newest first. */
    val tiles: List<FileNoteTile>
        get() = notes.values.groupBy { it.sha256 }.map { (sha, group) ->
            val ordered = group.sortedWith(compareByDescending<FileNote> { it.createdAt }.thenBy { it.id })
            val urls = ordered.flatMap { it.urls }.distinct()
            FileNoteTile(sha, ordered[0].mime, ordered[0].size, ordered[0].createdAt, urls)
        }.sortedWith(compareByDescending<FileNoteTile> { it.createdAt }.thenBy { it.sha256 })

    private fun seen(at: Long) {
        if (at > (newestSeen ?: Long.MIN_VALUE)) newestSeen = at
    }

    companion object {
        /** Back this far on a resubscribe, for notes stamped a little late. */
        const val RESUBSCRIBE_OVERLAP = 600L
    }
}

/** Tag values by name, from an event's raw tags (non-string entries dropped, as Apple's compactMap). */
private class StringTags(private val tags: List<List<String>>) {
    fun first(name: String): String? = all(name).firstOrNull()

    fun all(name: String): List<String> = tags.mapNotNull { if (it.size >= 2 && it[0] == name) it[1] else null }

    companion object {
        fun of(event: JsonObject): StringTags? {
            val raw = event["tags"] as? JsonArray ?: return null
            return StringTags(raw.map { tag ->
                (tag as? JsonArray)?.mapNotNull { (it as? JsonPrimitive)?.takeIf { p -> p.isString }?.contentOrNull }.orEmpty()
            })
        }
    }
}

private fun JsonObject.string(key: String): String? = (this[key] as? JsonPrimitive)?.takeIf { it.isString }?.contentOrNull

private fun JsonObject.int(key: String): Int? = (this[key] as? JsonPrimitive)?.takeIf { !it.isString }?.intOrNull
