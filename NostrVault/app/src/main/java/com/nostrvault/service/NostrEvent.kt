package com.nostrvault.service

// ══════════════════════════════════════════════════════════════════
// Data types
// ══════════════════════════════════════════════════════════════════

@kotlinx.serialization.Serializable
data class NostrEvent(
    val id: String,
    val pubkey: String,
    val createdAt: Long,
    val kind: Int,
    val tags: List<List<String>>,
    val content: String,
    val sig: String,
) {
    val createdAtDate: Long get() = createdAt * 1000 // Convert to millis
}
