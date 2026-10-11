package com.nostrvault.service

import android.util.Log
import com.nostrvault.BuildConfig
import com.nostrvault.data.model.BlockedPeople
import kotlinx.coroutines.*
import kotlinx.coroutines.flow.*
import kotlinx.serialization.json.*
import com.nostrvault.service.DMService.Companion.OPTIMISTIC_DEDUP_THRESHOLD_MS
import com.nostrvault.service.DMService.Companion.TAG

    /** Drops one message (a failed send's optimistic copy) from a conversation. */
    internal fun DMService.removeMessageFromConversation(counterparty: String, messageId: String) {
        val current = _conversations.value.toMutableList()
        val index = current.indexOfFirst { it.id == counterparty }
        if (index < 0) return
        val conv = current[index]
        val remaining = conv.messages.filterNot { it.id == messageId }
        if (remaining.size == conv.messages.size) return
        if (remaining.isEmpty()) current.removeAt(index) else current[index] = conv.copy(messages = remaining)
        _conversations.value = current
        saveCachedConversations()
    }

    internal fun DMService.addMessageToConversation(counterparty: String, message: DMMessage) {
        // Kept even from a blocked sender (hidden, not lost), but never unread.
        val alerts = BlockedPeople.mayAlert(message.senderPubkey, message.isFromMe, blockedHex())
        val current = _conversations.value.toMutableList()
        val existingIndex = current.indexOfFirst { it.id == counterparty }

        if (existingIndex >= 0) {
            val conv = current[existingIndex]
            // Already have this exact event — nothing to do.
            if (conv.messages.any { it.id == message.id }) return
            // Optimistic-send dedup: a message WE sent echoes back from the relay
            // with a real id; collapse it onto the optimistic copy. Gate on
            // isFromMe — applying this to inbound messages dropped distinct DMs
            // with identical short content (e.g. "ok"), so they were never cached
            // and got re-decrypted (re-prompting Amber) on every refresh.
            val isDuplicate = message.isFromMe && conv.messages.any { existing ->
                existing.isFromMe &&
                    existing.content == message.content &&
                    kotlin.math.abs(existing.timestamp - message.timestamp) < OPTIMISTIC_DEDUP_THRESHOLD_MS / 1000
            }
            if (isDuplicate) return

            val updatedMessages = (conv.messages + message).sortedBy { it.timestamp }
            val unread = if (alerts) conv.unreadCount + 1 else conv.unreadCount
            current[existingIndex] = conv.copy(
                messages = updatedMessages,
                unreadCount = unread,
            )
        } else {
            current.add(
                DMConversation(
                    id = counterparty,
                    messages = listOf(message),
                    unreadCount = if (alerts) 1 else 0,
                )
            )
        }

        // Sort by most recent
        current.sortByDescending { it.lastMessage?.timestamp ?: 0L }
        _conversations.value = current
        if (BuildConfig.DEBUG) Log.w(TAG, "DBG: addMessageToConversation cp=${counterparty.take(12)} → convos=${current.size}")
        saveCachedConversations()
    }

    // ══════════════════════════════════════════════════════════════════
    // Unread management
    // ══════════════════════════════════════════════════════════════════

    fun DMService.markRead(pubkey: String) {
        val current = _conversations.value.toMutableList()
        val idx = current.indexOfFirst { it.id == pubkey }
        if (idx >= 0) {
            current[idx] = current[idx].copy(unreadCount = 0)
            _conversations.value = current
            saveCachedConversations()
        }
    }
