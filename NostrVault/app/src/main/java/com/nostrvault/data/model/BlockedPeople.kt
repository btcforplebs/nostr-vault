package com.nostrvault.data.model

/**
 * What a block means for direct messages. A gift-wrapped DM is signed by a
 * throwaway key, so neither the relay nor the notification marker can tell who
 * sent it; only the opened message names the person. These checks run on that
 * real sender.
 *
 * A block hides, it never deletes: a blocked person's messages stay stored, so
 * unblocking brings the conversation back. iOS: BlockedPeople.swift.
 */
object BlockedPeople {
    fun isBlocked(hexPubkey: String, blocked: Set<String>): Boolean =
        hexPubkey.isNotEmpty() && hexPubkey.lowercase() in blocked

    /**
     * Conversations are keyed by the other person's hex pubkey. One with a
     * blocked person is left out, including what you sent them.
     */
    fun <C> visibleConversations(conversations: List<C>, blocked: Set<String>, counterparty: (C) -> String): List<C> =
        if (blocked.isEmpty()) conversations
        else conversations.filterNot { isBlocked(counterparty(it), blocked) }

    /**
     * Whether an incoming message counts as unread and may notify. Your own
     * copies never do; a blocked sender never does, so unblocking does not
     * surface a backlog of unread messages from while they were blocked.
     */
    fun mayAlert(sender: String, isFromMe: Boolean, blocked: Set<String>): Boolean =
        !isFromMe && !isBlocked(sender, blocked)
}
