package com.nostrvault.ui.screens.profile

import androidx.compose.runtime.Composable
import androidx.compose.runtime.State
import androidx.compose.runtime.derivedStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.structuralEqualityPolicy
import com.nostrvault.data.model.FeedNote
import com.nostrvault.data.model.FeedProfile
import com.nostrvault.ui.components.NostrMentions

/**
 * The profiles one card on a profile page can draw: its author, reposter,
 * "reply to" name, mentions and quoted notes' authors. Read through
 * derivedStateOf, so a profile arriving for anyone else (the map is
 * app-wide) doesn't recompose the card (perf review 2026-11-27 #7).
 */
@Composable
internal fun rememberCardProfiles(
    note: FeedNote,
    profiles: State<Map<String, FeedProfile>>,
    quotedNotes: State<Map<String, FeedNote>>,
): State<Map<String, FeedProfile>> {
    val head = remember(note.id) {
        buildList {
            add(note.pubkey)
            note.repostedBy?.let(::add)
            note.replyToPubkey?.let(::add)
            addAll(NostrMentions.mentionedPubkeys(note.content))
        }.distinct()
    }
    return remember(note.id) {
        derivedStateOf(structuralEqualityPolicy()) {
            val all = profiles.value
            val quoted = note.quotedEventIds.mapNotNull { quotedNotes.value[it]?.pubkey }
            val out = HashMap<String, FeedProfile>(head.size + quoted.size)
            for (pk in head) all[pk]?.let { out[pk] = it }
            for (pk in quoted) all[pk]?.let { out[pk] = it }
            out
        }
    }
}

/** The quoted notes [note] shows, out of the app-wide cache, read the same narrow way. */
@Composable
internal fun rememberCardQuotes(note: FeedNote, quotedNotes: State<Map<String, FeedNote>>): State<Map<String, FeedNote>> =
    remember(note.id) {
        derivedStateOf(structuralEqualityPolicy()) {
            if (note.quotedEventIds.isEmpty()) emptyMap()
            else note.quotedEventIds.mapNotNull { id -> quotedNotes.value[id]?.let { id to it } }.toMap()
        }
    }

/** Newest first, the way the profile's lists are kept. */
internal object ProfileNoteOrder {
    /**
     * [notes] (newest first) with [note] put in its place, after any note
     * of the same time, as a full re-sort would. O(log n) to find, instead
     * of re-sorting the whole list for every live note.
     */
    fun inserted(notes: List<FeedNote>, note: FeedNote): List<FeedNote> {
        var lo = 0
        var hi = notes.size
        while (lo < hi) {
            val mid = (lo + hi) ushr 1
            if (notes[mid].createdAt >= note.createdAt) lo = mid + 1 else hi = mid
        }
        return ArrayList<FeedNote>(notes.size + 1).apply {
            addAll(notes.subList(0, lo)); add(note); addAll(notes.subList(lo, notes.size))
        }
    }
}
