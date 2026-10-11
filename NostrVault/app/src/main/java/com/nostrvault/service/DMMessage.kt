package com.nostrvault.service

import kotlinx.serialization.Serializable

@Serializable
data class DMMessage(
    val id: String,
    val content: String,
    val timestamp: Long,
    val senderPubkey: String,
    val isFromMe: Boolean,
    val isNIP04: Boolean = false,
)
