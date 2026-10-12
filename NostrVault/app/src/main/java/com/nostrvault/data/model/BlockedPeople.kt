package com.nostrvault.data.model

import com.nostrvault.relay.HavenConfig

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

    /**
     * [npub] unblocked for the active account. The page lists
     * [HavenConfig.blockedForActiveAccount], which falls back to the legacy flat
     * list while the account has no list of its own, so the unblock starts from
     * that same list. For the owner the legacy list is cleared of [npub] too:
     * the relay's blacklist unions it in, so a leftover entry kept the relay
     * blocking someone the page no longer shows, and it was saved that way.
     * iOS: ConfigService.unblockProfile.
     */
    fun unblock(config: HavenConfig, npub: String): HavenConfig {
        val key = config.activeOrOwnerNpub()
        val rest = config.blockedFor(key).filter { it != npub }
        val legacy = config.blockedNpubs
        return config.copy(
            blockedNpubsPerAccount = config.blockedNpubsPerAccount + (key to rest),
            blockedNpubs = if (key == config.ownerNpub && legacy != null) legacy.filter { it != npub } else legacy,
        )
    }
}
