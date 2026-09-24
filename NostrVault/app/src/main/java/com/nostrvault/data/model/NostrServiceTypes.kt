package com.nostrvault.data.model

/**
 * Port of NostrServiceTypes.swift -- types for Nostr service layer.
 */

// ---------------------------------------------------------------------------
// Search results
// ---------------------------------------------------------------------------

data class GlobalSearchResults(
    val profiles: List<FeedProfile> = emptyList(),
    val notes: List<FeedNote> = emptyList(),
)

// ---------------------------------------------------------------------------
// Profile update signal (for efficient UI re-renders)
// ---------------------------------------------------------------------------

data class ProfileUpdateSignal(
    val generation: Int = 0,
    val pubkeys: Set<String> = emptySet(),
)
