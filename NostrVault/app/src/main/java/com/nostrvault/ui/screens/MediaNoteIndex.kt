package com.nostrvault.ui.screens

import com.nostrvault.data.model.FeedNote

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
 * hash → note id, for every blob referenced by a loaded note.
 *
 * When two notes reference the same blob the **oldest** wins: that is the post
 * the file was uploaded for, and a later quote or repost of the same image is
 * not where you meant to land. Ties break on id so the map is stable rather
 * than dependent on the order notes happened to arrive.
 */
internal fun noteIdsByBlobHash(notes: List<FeedNote>): Map<String, String> {
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
    return best.mapValues { it.value.id }
}
