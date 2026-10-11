package com.nostrvault.service

import com.nostrvault.data.model.*
import com.nostrvault.data.remote.WebSocketClient
import kotlinx.coroutines.*
import kotlinx.coroutines.flow.*
import kotlinx.serialization.json.*
import com.nostrvault.service.FeedService.Companion.MAX_INJECTED_IDS

    /** Take a like back locally only (a reaction that was never signed). */
    fun FeedService.unlikeNote(noteId: String) {
        _likedEventIds.value = _likedEventIds.value - noteId
        _myReactions.value = _myReactions.value - noteId
        bumpReactionCount(noteId, -1)
        saveInteractionState()
    }

    /** Zap a note (placeholder — full zap flow requires LNURL). */
    fun FeedService.zapNote(noteId: String, amount: Long) {
        val existing = _zappedEventIds.value.toMutableMap()
        existing[noteId] = (existing[noteId] ?: 0) + amount.toInt()
        _zappedEventIds.value = existing

        val stats = _noteStats.value.toMutableMap()
        val existing2 = stats[noteId] ?: NoteStats()
        stats[noteId] = existing2.copy(
            zapCount = existing2.zapCount + 1,
            zapAmountSats = existing2.zapAmountSats + amount,
        )
        _noteStats.value = stats
    }

    fun FeedService.injectExternalEvent(eventJson: String, eventId: String) {
        if (!injectedEventIds.add(eventId)) return
        if (injectedEventIds.size > MAX_INJECTED_IDS) {
            injectedEventIds.clear()
        }

        val config = configStore.config.value
        val inboxUrl = config.localInboxURL ?: return

        scope.launch(Dispatchers.IO) {
            val client = WebSocketClient(url = inboxUrl, scope = scope, trustLocalhost = true)
            client.connect()
            client.send("[\"EVENT\",$eventJson]")
            delay(300)
            client.disconnect()
        }
    }
