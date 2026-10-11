package com.nostrvault.data.model

// ---------------------------------------------------------------------------
// Per-note engagement details (who reacted / zapped / reposted)
// ---------------------------------------------------------------------------

data class ReactionDetail(
    val id: String,
    val pubkey: String,
    val emoji: String,
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
