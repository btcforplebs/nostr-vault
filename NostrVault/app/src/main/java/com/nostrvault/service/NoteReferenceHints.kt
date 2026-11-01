package com.nostrvault.service

import com.nostrvault.data.model.FeedNote

/**
 * Where to look for a note other notes point at: the relay hint and author
 * the first referencing note gives for it. Feed notes are asked first, then
 * notes opened or fetched outside the feed (the thread page's opened reply
 * lives in the parent cache), so a reply opened from a profile or a
 * notification still leads to its parent's relays.
 */
internal object NoteReferenceHints {

    /** (relay hint, author hex) for [id] from the first note in [notes] that references it. */
    fun find(id: String, notes: Sequence<FeedNote>): Pair<String?, String?>? {
        for (note in notes) {
            val tag = note.tags.firstOrNull { it.size >= 2 && (it[0] == "e" || it[0] == "q") && it[1] == id } ?: continue
            val hint = tag.getOrNull(2)?.takeIf { it.startsWith("wss://") || it.startsWith("ws://") }
            val author = tag.getOrNull(4)?.takeIf { it.length == 64 }
                ?: tag.getOrNull(3)?.takeIf { tag[0] == "q" && it.length == 64 }
                ?: if (note.parentEventId == id) note.tags.lastOrNull { it.size >= 2 && it[0] == "p" }?.get(1) else null
            return hint to author
        }
        return null
    }
}
