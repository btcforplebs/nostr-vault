package com.nostrvault.service

import kotlinx.serialization.Serializable

// ── Data models ───────────────────────────────────────────────────

@Serializable
data class DMConversation(
    val id: String, // counterparty hex pubkey
    val messages: List<DMMessage>,
    val unreadCount: Int = 0,
) {
    val lastMessage: DMMessage?
        get() = messages.lastOrNull()

    val hasNIP04Messages: Boolean
        get() = messages.any { it.isNIP04 }
}
