package com.nostrvault.service

import com.nostrvault.data.model.*
import kotlinx.coroutines.*
import kotlinx.coroutines.flow.*
import kotlinx.serialization.json.*

    // ══════════════════════════════════════════════════════════════════

    // Local relay operations

    // ══════════════════════════════════════════════════════════════════

    /**
     * Keeps a copy of a post you liked on your own relay. Its root stores only
     * your events and its inbox only events that tag you, so a liked post
     * lived nowhere local and Relay > Likes > Given had to find it on outside
     * relays, which on iOS returned 47 of 293. The /feed store takes any note
     * and keeps the feed window (iOS #295).
     */
    internal fun FeedService.keepLikedNoteLocally(noteId: String) {
        val raw = rawEventCache[noteId] ?: return
        val feedUrl = configStore.config.value.localRelayURL("feed") ?: return
        feedClients[feedUrl]?.send("[\"EVENT\",$raw]")
    }
