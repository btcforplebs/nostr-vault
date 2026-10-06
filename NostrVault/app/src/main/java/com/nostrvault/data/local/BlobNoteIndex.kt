package com.nostrvault.data.local

import android.content.Context
import com.nostrvault.data.model.FeedNote
import dagger.hilt.android.qualifiers.ApplicationContext
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.Job
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.delay
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.asStateFlow
import kotlinx.coroutines.launch
import kotlinx.coroutines.sync.Mutex
import kotlinx.coroutines.sync.withLock
import kotlinx.coroutines.withContext
import kotlinx.serialization.Serializable
import kotlinx.serialization.encodeToString
import kotlinx.serialization.json.Json
import java.io.File
import javax.inject.Inject
import javax.inject.Singleton

/**
 * Maps a Blossom blob back to the note that posted it.
 *
 * The media gallery lists *blobs* — files on your local Blossom directory and
 * its mirrors. A blob carries no note reference, because nothing put one there:
 * `BlossomMediaItem.noteId` has a `null` default and no construction site ever
 * passes it. So "open the note behind this media item" had no data behind it,
 * not just a missing wire.
 *
 * The join that does exist is the sha256. A Blossom URL is `<server>/<hash>`
 * with an optional extension, so a note's `mediaURLs` carry the hash of every
 * blob they reference, and matching on the hash works across mirrors — the same
 * file served from two servers has two URLs and one hash.
 */
private val SHA256_IN_URL = Regex("(?<![0-9a-fA-F])[0-9a-fA-F]{64}(?![0-9a-fA-F])")

/** The 64-hex sha256 in a Blossom URL, or null if the URL does not carry one. */
internal fun blobHashInUrl(url: String): String? =
    SHA256_IN_URL.find(url.substringBefore('?').substringBefore('#'))
        ?.value
        ?.lowercase()

/**
 * hash → note id, for every blob referenced by the given notes.
 *
 * When two notes reference the same blob the **oldest** wins: that is the post
 * the file was uploaded for, and a later quote or repost of the same image is
 * not where you meant to land. Ties break on id so the map is stable rather
 * than dependent on the order notes happened to arrive.
 */
internal fun noteIdsByBlobHash(notes: List<FeedNote>): Map<String, String> =
    oldestNoteByBlobHash(notes).mapValues { it.value.id }

/** hash → the note [noteIdsByBlobHash] picks for it, whole, so its author is at hand too. */
internal fun oldestNoteByBlobHash(notes: List<FeedNote>): Map<String, FeedNote> {
    val best = HashMap<String, FeedNote>()
    for (note in notes) {
        for (url in note.mediaURLs) {
            val hash = blobHashInUrl(url) ?: continue
            val existing = best[hash]
            if (existing == null ||
                note.createdAt < existing.createdAt ||
                (note.createdAt == existing.createdAt && note.id < existing.id)
            ) {
                best[hash] = note
            }
        }
    }
    return best
}

/**
 * The hash → note index, kept on disk.
 *
 * Computing this from `FeedService.notes` alone made the "Open Note" item on a
 * blob a property of *the session*: the same file offered it or did not,
 * depending on how far the feed happened to have been scrolled earlier. The
 * user cannot see the feed cache and cannot predict it, so the affordance
 * flickered in and out for reasons nothing on screen explains.
 *
 * Persisting it makes the answer a property of the blob. The index only ever
 * grows: every note the feed has *ever* handed us contributes its blob hashes,
 * and they stay after the note is evicted from memory or the app is killed.
 *
 * Not per-account. A blob's originating note is a fact about public events, not
 * about who is logged in, and an index keyed by account would re-learn the same
 * mapping once per identity.
 */
@Singleton
class BlobNoteIndexStore @Inject constructor(
    @ApplicationContext context: Context,
) {
    companion object {
        /**
         * Entry ceiling. An entry is three hex ids, so 20k of them is roughly 4.5MB
         * of JSON — large enough that no ordinary library reaches it, small
         * enough to stay a file rather than a database. Over the cap the
         * *newest* notes are kept: the gallery is browsed from the recent end.
         */
        private const val MAX_ENTRIES = 20_000
        private const val WRITE_DEBOUNCE_MS = 2_000L
    }

    /** [pubkey] is the note's author; null in entries written before it was kept. */
    @Serializable
    private data class Entry(val noteId: String, val createdAt: Long, val pubkey: String? = null)

    @Serializable
    private data class Persisted(val entries: Map<String, Entry> = emptyMap())

    private val json = Json { ignoreUnknownKeys = true }
    private val dataDir = File(context.filesDir, "nostrvault_data")
    private val file = File(dataDir, "blob_note_index.json")

    private val scope = CoroutineScope(SupervisorJob() + Dispatchers.IO)
    private val mutex = Mutex()

    /** hash → entry. Guarded by [mutex]; never read directly by the UI. */
    private val entries = HashMap<String, Entry>()

    /** Note ids already folded in, so a re-emission of the same list costs a set lookup. */
    private val indexedNoteIds = HashSet<String>()

    private var writeJob: Job? = null

    private val _index = MutableStateFlow<Map<String, String>>(emptyMap())

    /** hash → note id, for every blob this device has ever seen referenced. */
    val index: StateFlow<Map<String, String>> = _index.asStateFlow()

    private val _authors = MutableStateFlow<Map<String, String>>(emptyMap())

    /**
     * hash → author of the note in [index], where known. The media tab's
     * Report Media / Block User target (iOS MediaItem.pubkey).
     */
    val authors: StateFlow<Map<String, String>> = _authors.asStateFlow()

    init {
        scope.launch { load() }
    }

    private suspend fun load() = mutex.withLock {
        val loaded = try {
            if (file.exists()) json.decodeFromString<Persisted>(file.readText()).entries else emptyMap()
        } catch (_: Exception) {
            // A corrupt or half-written file costs the index, not the gallery:
            // it rebuilds itself from the next notes that arrive.
            emptyMap()
        }
        entries.putAll(loaded)
        publish()
    }

    /**
     * Fold a batch of notes into the index.
     *
     * Cheap to call with the same list twice — a note id already folded in is
     * skipped on a set lookup, which is what makes it safe to hang off
     * `FeedService.notes` rather than off a load event.
     */
    suspend fun record(notes: List<FeedNote>) {
        val fresh = notes.filter { it.id !in indexedNoteIds }
        if (fresh.isEmpty()) return

        val additions = withContext(Dispatchers.Default) { noteIdsByBlobHashWithTime(fresh) }
        mutex.withLock {
            fresh.forEach { indexedNoteIds.add(it.id) }
            var changed = false
            for ((hash, entry) in additions) {
                val existing = entries[hash]
                // Same oldest-wins rule as the in-memory helper, applied across
                // sessions: a later quote of the same image does not take the
                // slot from the post the file was uploaded for.
                if (existing == null ||
                    entry.createdAt < existing.createdAt ||
                    (entry.createdAt == existing.createdAt && entry.noteId < existing.noteId) ||
                    // The same note seen again fills in an author an older file lacked.
                    (entry.noteId == existing.noteId && existing.pubkey == null && entry.pubkey != null)
                ) {
                    entries[hash] = entry
                    changed = true
                }
            }
            if (!changed) return@withLock
            evictIfOverCap()
            publish()
            scheduleWrite()
        }
    }

    private fun noteIdsByBlobHashWithTime(notes: List<FeedNote>): Map<String, Entry> =
        oldestNoteByBlobHash(notes).mapValues { (_, note) -> Entry(note.id, note.createdAt.time, note.pubkey) }

    private fun evictIfOverCap() {
        if (entries.size <= MAX_ENTRIES) return
        val keep = entries.entries
            .sortedByDescending { it.value.createdAt }
            .take(MAX_ENTRIES)
            .associate { it.key to it.value }
        entries.clear()
        entries.putAll(keep)
    }

    private fun publish() {
        _index.value = entries.mapValues { it.value.noteId }
        _authors.value = entries.mapNotNull { (hash, e) -> e.pubkey?.let { hash to it } }.toMap()
    }

    /**
     * Debounced so a feed backfill delivering batches a few hundred
     * milliseconds apart writes the file once, not once per batch.
     */
    private fun scheduleWrite() {
        writeJob?.cancel()
        writeJob = scope.launch {
            delay(WRITE_DEBOUNCE_MS)
            val snapshot = mutex.withLock { Persisted(HashMap(entries)) }
            try {
                dataDir.mkdirs()
                val tmp = File(dataDir, "blob_note_index.json.tmp")
                tmp.writeText(json.encodeToString(snapshot))
                // Rename rather than write in place: a kill mid-write leaves the
                // previous index intact instead of a truncated file.
                if (!tmp.renameTo(file)) {
                    file.writeText(tmp.readText())
                    tmp.delete()
                }
            } catch (_: Exception) {
            }
        }
    }
}
