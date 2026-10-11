package com.nostrvault.data.model

import kotlinx.serialization.SerialName
import kotlinx.serialization.Serializable

// ---------------------------------------------------------------------------
// Popular notes DVM result
// ---------------------------------------------------------------------------

@Serializable
data class PopularNoteResult(
    val id: String,
    val pubkey: String,
    val content: String,
    @SerialName("created_at") val createdAt: Long,
    val tags: List<List<String>>,
    val kind: Int,
    val score: Double,
)
