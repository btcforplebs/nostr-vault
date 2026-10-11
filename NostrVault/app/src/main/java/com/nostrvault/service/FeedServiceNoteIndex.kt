package com.nostrvault.service

import com.nostrvault.data.model.*
import kotlinx.coroutines.*
import kotlinx.coroutines.flow.*
import kotlinx.coroutines.sync.withLock
import kotlinx.serialization.json.*
import kotlin.concurrent.withLock

    // ══════════════════════════════════════════════════════════════════
    // Note operations
    // ══════════════════════════════════════════════════════════════════

    fun FeedService.addNote(note: FeedNote) {
        // Register the id so the relay echo of this note is deduped — without
        // this the optimistic insert + the echo produce a duplicate id, which
        // crashes the LazyColumn (duplicate key) and, once snapshotted,
        // crash-loops every launch.
        seenIdsLock.withLock { seenIds.add(note.id) }
        _notes.value = (listOf(note) + _notes.value).distinctBy { it.id }
        recomputeFilteredNotes()
    }

    internal fun FeedService.noteIndex(): Map<String, FeedNote> {
        val notes = _notes.value
        noteIndex?.let { (list, map) -> if (list === notes) return map }
        val map = HashMap<String, FeedNote>(notes.size * 2)
        for (note in notes) {
            map.putIfAbsent(note.id, note)
            map.putIfAbsent(note.effectiveEventId, note)
        }
        noteIndex = notes to map
        return map
    }
