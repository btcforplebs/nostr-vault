package com.nostrvault.relay

/** Per-account push notification preferences (mirrors iOS). */
@kotlinx.serialization.Serializable
data class PushPrefs(
    val mentions: Boolean = true,
    val replies: Boolean = true,
    val dms: Boolean = true,
    val zaps: Boolean = true,
    val reactions: Boolean = false,
    val reposts: Boolean = false,
    /** Someone new follows this account (or comes back after a week away). */
    val follows: Boolean = true,
) {
    /**
     * Whether any notification at all is wanted. The relay's catch-up summary
     * ("N more new items while you were away") counts events of every type at
     * once, so no single preference governs it — but turning everything off has
     * to silence it too, which it previously did not.
     */
    val wantsAnything: Boolean
        get() = mentions || replies || dms || zaps || reactions || reposts
}
