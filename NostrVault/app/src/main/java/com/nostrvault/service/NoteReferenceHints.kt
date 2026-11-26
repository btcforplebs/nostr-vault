package com.nostrvault.service

import com.nostrvault.data.model.FeedNote
import com.nostrvault.relay.DMInbox

/**
 * Where to look for a note other notes point at: the relay hint and author
 * the first referencing note gives for it. Feed notes are asked first, then
 * notes opened or fetched outside the feed (the thread page's opened reply
 * lives in the parent cache), so a reply opened from a profile or a
 * notification still leads to its parent's relays.
 *
 * NIP-22 comments name their root only in an uppercase `E` tag, with the
 * author in the fourth slot, and a phone-only poster's hint is their own
 * `ws://127.0.0.1` (2026-11-26 Mostr thread): `E` tags count, loopback/LAN
 * hints are dropped. iOS twin: `ParentLookupRelays.hints`.
 */
internal object NoteReferenceHints {

    /** (relay hint, author hex) for [id] from the first note in [notes] that references it. */
    fun find(id: String, notes: Sequence<FeedNote>): Pair<String?, String?>? {
        for (note in notes) {
            val tag = note.tags.firstOrNull { it.size >= 2 && it[0] in REF_TAGS && it[1] == id } ?: continue
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
                if (tag.size < 2 || tag[0] !in REF_TAGS) continue
                val id = tag[1]
                if (id !in ids || id in out) continue
                out[id] = hints(id, tag, note)
            }
            if (out.size == ids.size) break
        }
        return out
    }

    private fun hints(id: String, tag: List<String>, note: FeedNote): Pair<String?, String?> {
        val hint = tag.getOrNull(2)?.let(::reachableHint)
        // NIP-10 puts the author fifth; NIP-22 `e`/`E` and `q` fourth, where
        // NIP-10 has its marker, which is never 64 hex characters.
        val author = tag.getOrNull(4)?.takeIf(::isHexKey)
            ?: tag.getOrNull(3)?.takeIf(::isHexKey)
            ?: if (note.parentEventId == id) note.tags.lastOrNull { it.size >= 2 && it[0] == "p" }?.get(1) else null
        return hint to author
    }

    private val REF_TAGS = setOf("e", "E", "q")

    /** [raw] when it is a websocket address others can reach: not loopback or LAN. */
    fun reachableHint(raw: String): String? {
        val url = raw.trim()
        val lower = url.lowercase()
        val hostPort = when {
            lower.startsWith("wss://") -> url.substring(6)
            lower.startsWith("ws://") -> url.substring(5)
            else -> return null
        }
        return url.takeIf { hostPort.isNotEmpty() && !DMInbox.isPrivateNetworkHost(hostPort) }
    }

    private fun isHexKey(s: String) = s.length == 64 && s.all { it in '0'..'9' || it in 'a'..'f' || it in 'A'..'F' }
}
