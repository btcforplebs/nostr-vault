package com.nostrvault.ui.screens.dm

import com.nostrvault.data.model.FeedProfile
import com.nostrvault.service.DMConversation

/**
 * Messages search (Logen 2026-11-03, c2bba1de): names and message text, on the device only. It reads the
 * conversations already in memory (messages already decrypted) and never sends the query anywhere.
 */
internal object DMInboxSearch {
    /** The conversations matching [query]: by the person's name, display name or NIP-05, or any message's text. */
    fun filter(
        conversations: List<DMConversation>,
        query: String,
        profileFor: (String) -> FeedProfile?,
    ): List<DMConversation> {
        val q = query.trim().lowercase()
        if (q.isEmpty()) return conversations
        return conversations.filter { matches(it, profileFor(it.id), q) }
    }

    private fun matches(conversation: DMConversation, profile: FeedProfile?, q: String): Boolean {
        val names = listOfNotNull(profile?.displayName, profile?.name, profile?.nip05)
        if (names.any { it.lowercase().contains(q) }) return true
        return conversation.messages.any { it.content.lowercase().contains(q) }
    }
}
