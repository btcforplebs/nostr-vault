package com.nostrvault.ui.screens

import androidx.lifecycle.ViewModel
import androidx.lifecycle.viewModelScope
import com.nostrvault.data.local.ConfigStore
import com.nostrvault.data.model.FeedProfile
import com.nostrvault.data.model.LiveStream
import com.nostrvault.service.FeedService
import com.nostrvault.service.LiveChatService
import com.nostrvault.service.LiveFeedService
import com.nostrvault.service.NostrService
import com.nostrvault.service.ZapSendService
import dagger.hilt.android.lifecycle.HiltViewModel
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.asStateFlow
import kotlinx.coroutines.launch
import javax.inject.Inject

/**
 * Chat and zaps for the stream on screen.
 *
 * Joining connects to the streaming relays for as long as this screen is up;
 * leaving disconnects. A live room's traffic is not something to keep a socket
 * open for behind a screen nobody is watching.
 */
@HiltViewModel
class LiveStreamViewModel @Inject constructor(
    private val liveChatService: LiveChatService,
    private val zapSendService: ZapSendService,
    private val nostrService: NostrService,
    private val feedService: FeedService,
    private val blossomPickerMedia: BlossomPickerMedia,
    private val liveFeedService: LiveFeedService,
    private val configStore: ConfigStore,
) : ViewModel() {

    /** Wallet settings' default zap, in sats: where the zap sheet starts. */
    fun defaultZapAmount(): Int = configStore.config.value.defaultZapAmount

    val messages: StateFlow<List<LiveChatService.ChatEntry>> = liveChatService.messages

    /** Media for the chat's Blossom picker, the same list the composer shows. */
    suspend fun loadBlossomMedia(): List<BlossomMediaItem> = blossomPickerMedia.load()
    val profiles: StateFlow<Map<String, FeedProfile>> = nostrService.profiles

    /** Why the last zap failed, for the "Zap failed" alert; null when none. */
    private val _zapFailure = MutableStateFlow<String?>(null)
    val zapFailure: StateFlow<String?> = _zapFailure.asStateFlow()

    private val _sending = MutableStateFlow(false)
    val sending: StateFlow<Boolean> = _sending.asStateFlow()

    fun join(stream: LiveStream) {
        // One view model serves every stream opened (LiveStreamHost sits
        // outside the nav graph), so the last stream's zap failure must not carry over.
        _zapFailure.value = null
        liveChatService.join(stream)
    }

    fun leave() = liveChatService.leave()

    /** [onFailed] runs when no relay took the line, so the text can go back in the field. */
    fun send(stream: LiveStream, text: String, onFailed: () -> Unit) {
        viewModelScope.launch {
            _sending.value = true
            val ok = liveChatService.send(stream, text)
            _sending.value = false
            if (!ok) onFailed()
        }
    }

    /** The host has a Lightning address (LUD-06 or LUD-16) to pay. iOS lightningAddress(for:). */
    fun hasLightningAddress(pubkey: String): Boolean {
        val profile = nostrService.profiles.value[pubkey] ?: return false
        return !profile.lud06.isNullOrEmpty() || !profile.lud16.isNullOrEmpty()
    }

    /**
     * Zap the stream's host. The stream address goes on the zap request so the
     * receipt lands in this room's chat rather than only in the host's notes.
     * [comment] is what the owner typed; empty sends the default. Success is
     * silent, as on iOS: the receipt shows in the chat.
     */
    fun zap(stream: LiveStream, sats: Int, comment: String) {
        viewModelScope.launch {
            val result = zapSendService.zapNote(
                noteId = "",
                notePubkey = stream.hostPubkey,
                amountSats = sats,
                message = comment.ifEmpty { "Zap from Nostr Vault" },
                addressTag = stream.address,
            )
            result.exceptionOrNull()?.let { _zapFailure.value = it.message ?: "Zap failed" }
        }
    }

    fun clearZapFailure() { _zapFailure.value = null }

    /**
     * NIP-56 report of the stream's host (the stream event has no id to hand),
     * then a block, as reporting does everywhere else in the app.
     */
    fun reportHost(stream: LiveStream, reason: String, description: String) {
        viewModelScope.launch {
            nostrService.reportUser(stream.hostPubkey, reason, description.ifBlank { null })
            feedService.blockUser(stream.hostPubkey)
            liveFeedService.removeStreams(byHost = stream.hostPubkey)
        }
    }

    fun blockHost(stream: LiveStream) {
        viewModelScope.launch {
            feedService.blockUser(stream.hostPubkey)
            liveFeedService.removeStreams(byHost = stream.hostPubkey)
        }
    }

    /**
     * Reports the event that carries the text — the receipt, for a zap line,
     * which is attributed to the payer — and blocks its author.
     */
    fun reportMessage(entry: LiveChatService.ChatEntry, reason: String, description: String) {
        viewModelScope.launch {
            nostrService.reportEvent(entry.id, entry.pubkey, reason, description.ifBlank { null })
            feedService.blockUser(entry.pubkey)
        }
    }
}
