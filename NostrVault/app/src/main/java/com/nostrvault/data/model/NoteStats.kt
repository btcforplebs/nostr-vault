package com.nostrvault.data.model

import androidx.compose.runtime.Stable
import kotlinx.serialization.Serializable

// ---------------------------------------------------------------------------
// Per-note engagement counts
// ---------------------------------------------------------------------------

@Stable
@Serializable
data class NoteStats(
    var reactionCount: Int = 0,
    var repostCount: Int = 0,
    var zapCount: Int = 0,
    var zapAmountSats: Long = 0L,
) {
    /** Aliases for backward compatibility with UI code. */
    val reactions: Int get() = reactionCount
    val reposts: Int get() = repostCount
    val zaps: Int get() = zapCount
}
