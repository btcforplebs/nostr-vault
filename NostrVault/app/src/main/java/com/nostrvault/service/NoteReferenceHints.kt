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
            return hints(id, tag, note)
        }
        return null
    }

    /**
     * [find] for every id in [ids] in one walk over [notes]: same first note,
     * same first tag. A lookup batch used to call [find] per id, each walking
     * the whole feed, three times per batch (Moto check 11-01).
     */
    fun findEach(ids: Set<String>, notes: Sequence<FeedNote>): Map<String, Pair<String?, String?>> {
        val out = HashMap<String, Pair<String?, String?>>()
        if (ids.isEmpty()) return out
        for (note in notes) {
            for (tag in note.tags) {
                if (tag.size < 2 || (tag[0] != "e" && tag[0] != "q")) continue
                val id = tag[1]
                if (id !in ids || id in out) continue
                out[id] = hints(id, tag, note)
            }
            if (out.size == ids.size) break
        }
        return out
    }

    private fun hints(id: String, tag: List<String>, note: FeedNote): Pair<String?, String?> {
        val hint = tag.getOrNull(2)?.takeIf { it.startsWith("wss://") || it.startsWith("ws://") }
        val author = tag.getOrNull(4)?.takeIf { it.length == 64 }
            ?: tag.getOrNull(3)?.takeIf { tag[0] == "q" && it.length == 64 }
            ?: if (note.parentEventId == id) note.tags.lastOrNull { it.size >= 2 && it[0] == "p" }?.get(1) else null
        return hint to author
    }
}
