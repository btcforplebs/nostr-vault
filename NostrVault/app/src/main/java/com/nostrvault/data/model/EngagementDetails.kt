package com.nostrvault.data.model

// ---------------------------------------------------------------------------
// Per-note engagement details (who reacted / zapped / reposted)
// ---------------------------------------------------------------------------

data class ReactionDetail(
    val id: String,
    val pubkey: String,
    val emoji: String,
    /** Set when [emoji] is `:shortcode:` and the reaction's tag gives its image (NIP-30). */
    val customEmoji: com.nostrvault.service.CustomEmoji? = null,
)

data class ZapDetail(
    val id: String,
    val zapperPubkey: String,
    val amountSats: Long,
    val comment: String,
)

data class RepostDetail(
    val id: String,
    val pubkey: String,
)

data class EngagementDetails(
    val reactions: List<ReactionDetail> = emptyList(),
    val zaps: List<ZapDetail> = emptyList(),
    val reposts: List<RepostDetail> = emptyList(),
)
