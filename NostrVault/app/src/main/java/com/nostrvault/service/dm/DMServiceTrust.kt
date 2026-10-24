package com.nostrvault.service

import com.nostrvault.data.model.DMTrust
import kotlinx.coroutines.flow.Flow
import kotlinx.coroutines.flow.combine
import kotlinx.coroutines.flow.distinctUntilChanged
import kotlinx.coroutines.flow.emitAll
import kotlinx.coroutines.flow.flow

    /**
     * The Relay tab's trusted set, re-read whenever the trust graph or your
     * follows change. [FeedService] is only reached once collected.
     */
    internal fun DMService.trustedPubkeysFlow(): Flow<Set<String>> = flow {
        val feed = feedService.get()
        emitAll(
            combine(feed.wotPubkeys, feed.followedPubkeys) { _, _ -> feed.relayTabTrustedPubkeys() }
                .distinctUntilChanged(),
        )
    }

    private fun DMService.ownKeys(): Set<String> =
        setOf(nostrService.activeHexPubkey).filterTo(mutableSetOf()) { it.isNotEmpty() }

    internal fun DMService.splitInbox(
        conversations: List<DMConversation>,
        trusted: Set<String>,
    ): DMTrust.Split<DMConversation> =
        DMTrust.split(conversations, trusted, ownKeys(), { it.id }, { c -> c.messages.any { it.isFromMe } })

    /**
     * Whether a message from [counterparty] belongs in the main inbox, so it may
     * notify. Read live from the trust set, so a graph that just loaded counts.
     */
    fun DMService.isInboxConversation(counterparty: String): Boolean {
        val youWrote = _conversations.value.firstOrNull { it.id == counterparty }
            ?.messages?.any { it.isFromMe } == true
        val trusted = runCatching { feedService.get().relayTabTrustedPubkeys() }.getOrDefault(dmTrustedPubkeys.value)
        return DMTrust.isInbox(counterparty, youWrote, trusted, ownKeys())
    }
