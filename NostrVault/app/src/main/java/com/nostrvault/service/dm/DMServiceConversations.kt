package com.nostrvault.service

import android.util.Log
import com.nostrvault.BuildConfig
import com.nostrvault.data.model.BlockedPeople
import com.nostrvault.data.model.muteRulesForActiveAccount
import kotlinx.coroutines.*
import kotlinx.coroutines.flow.*
import kotlinx.serialization.json.*
import com.nostrvault.service.DMService.Companion.OPTIMISTIC_DEDUP_THRESHOLD_MS
import com.nostrvault.service.DMService.Companion.TAG

    /** Drops one message (a failed send's optimistic copy) from a conversation. */
    internal fun DMService.removeMessageFromConversation(counterparty: String, messageId: String) {
        val current = _conversations.value
        val remaining = current.withoutMessage(counterparty, messageId)
        if (remaining === current) return
        _conversations.value = remaining
        saveCachedConversations()
    }

    /** Whether [message] may raise the unread count (not blocked, no muted word). */
    private fun DMService.mayAlert(message: DMMessage): Boolean =
        // Kept even from a blocked sender (hidden, not lost), but never unread.
        // A muted word: kept, never unread (DMMutes).
        BlockedPeople.mayAlert(message.senderPubkey, message.isFromMe, blockedHex()) &&
            (message.isFromMe || !configStore.config.value.muteRulesForActiveAccount().hidesText(message.content))

    /** Adds one message on the calling (main) thread: sends and tests. Received DMs use [mergeMessage]. */
    internal fun DMService.addMessageToConversation(counterparty: String, message: DMMessage) {
        val current = _conversations.value
        val next = current.withMessage(counterparty, message, mayAlert(message), visibleConversation == counterparty)
        if (next === current) return
        _conversations.value = next
        if (BuildConfig.DEBUG) Log.w(TAG, "DBG: addMessageToConversation cp=${counterparty.take(12)} → convos=${next.size}")
        saveCachedConversations()
    }

    /**
     * Files a received message: the merge runs on Default, and only the
     * publish touches main. If the list changed while merging (another
     * message, a markRead, a status), the merge runs again on the new list;
     * after an account switch the message is dropped, as it belongs to the
     * other account.
     */
    internal suspend fun DMService.mergeMessage(counterparty: String, message: DMMessage) {
        val key = loadedCacheKey
        val alerts = mayAlert(message)
        while (true) {
            val base = _conversations.value
            val next = withContext(Dispatchers.Default) {
                base.withMessage(counterparty, message, alerts, visibleConversation == counterparty)
            }
            if (next === base) return
            val published = withContext(Dispatchers.Main.immediate) {
                when {
                    loadedCacheKey != key -> true // switched: not this inbox's message
                    _conversations.value !== base -> false
                    else -> {
                        _conversations.value = next
                        if (BuildConfig.DEBUG) Log.w(TAG, "DBG: mergeMessage cp=${counterparty.take(12)} → convos=${next.size}")
                        saveCachedConversations()
                        true
                    }
                }
            }
            if (published) return
        }
    }

    // ══════════════════════════════════════════════════════════════════
    // Unread management
    // ══════════════════════════════════════════════════════════════════

    fun DMService.markRead(pubkey: String) {
        val current = _conversations.value.toMutableList()
        val idx = current.indexOfFirst { it.id == pubkey }
        // Already read: nothing changed, so nothing to write.
        if (idx >= 0 && current[idx].unreadCount != 0) {
            current[idx] = current[idx].copy(unreadCount = 0)
            _conversations.value = current
            saveCachedConversations()
        }
    }

/**
 * This inbox with [message] filed under [counterparty], or this same list
 * when it is already there (same id, or the relay's echo of an optimistic
 * send). The list stays newest first and each chat oldest first; both are
 * kept by inserting in place, not by sorting again.
 */
internal fun List<DMConversation>.withMessage(
    counterparty: String,
    message: DMMessage,
    alerts: Boolean,
    onScreen: Boolean,
): List<DMConversation> {
    // A message that lands in the chat on screen is read as it arrives.
    val addsUnread = alerts && !onScreen
    val existingIndex = indexOfFirst { it.id == counterparty }
    val updated: DMConversation
    if (existingIndex >= 0) {
        val conv = this[existingIndex]
        // Already have this exact event — nothing to do.
        if (conv.messages.any { it.id == message.id }) return this
        // Optimistic-send dedup: a message WE sent echoes back from the relay
        // with a real id; collapse it onto the optimistic copy. Gate on
        // isFromMe — applying this to inbound messages dropped distinct DMs
        // with identical short content (e.g. "ok"), so they were never cached
        // and got re-decrypted (re-prompting Amber) on every refresh.
        val isDuplicate = message.isFromMe && conv.messages.any { existing ->
            existing.isFromMe &&
                // A Not sent bubble is never the copy a new message echoes (its Try again resends).
                existing.sendState != DMSendState.FAILED &&
                existing.content == message.content &&
                kotlin.math.abs(existing.timestamp - message.timestamp) < OPTIMISTIC_DEDUP_THRESHOLD_MS / 1000
        }
        if (isDuplicate) return this
        // After every message with the same or an earlier time, as a stable sort would put it.
        val messages = conv.messages.toMutableList()
        var at = messages.size
        while (at > 0 && messages[at - 1].timestamp > message.timestamp) at--
        messages.add(at, message)
        updated = conv.copy(messages = messages, unreadCount = if (addsUnread) conv.unreadCount + 1 else conv.unreadCount)
    } else {
        updated = DMConversation(id = counterparty, messages = listOf(message), unreadCount = if (addsUnread) 1 else 0)
    }
    val out = toMutableList()
    if (existingIndex >= 0) out.removeAt(existingIndex)
    // Newest first; a chat keeps its place among others of the same time.
    val time = updated.lastMessage?.timestamp ?: 0L
    var at = 0
    while (at < out.size && (out[at].lastMessage?.timestamp ?: 0L) > time) at++
    if (existingIndex >= 0) {
        // Ties: stay ahead of the chats that were after it, behind those that were before.
        while (at < existingIndex && at < out.size && (out[at].lastMessage?.timestamp ?: 0L) == time) at++
    } else {
        while (at < out.size && (out[at].lastMessage?.timestamp ?: 0L) == time) at++
    }
    out.add(at, updated)
    return out
}
