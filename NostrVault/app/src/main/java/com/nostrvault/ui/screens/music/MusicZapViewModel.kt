package com.nostrvault.ui.screens.music

import androidx.lifecycle.ViewModel
import androidx.lifecycle.viewModelScope
import com.nostrvault.data.local.ConfigStore
import com.nostrvault.data.model.FeedProfile
import com.nostrvault.service.NostrService
import com.nostrvault.service.ZapSendService
import com.nostrvault.ui.notification.NotificationManager
import dagger.hilt.android.lifecycle.HiltViewModel
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.launch
import javax.inject.Inject

/**
 * Zap the artist from the now-playing tray: the same zap as a profile's Zap pill, to the person, not
 * a note (no `e` tag, NIP-57). iOS: ArtistZapPill (NowPlayingView.swift, #1084).
 */
@HiltViewModel
class MusicZapViewModel @Inject constructor(
    private val nostrService: NostrService,
    private val zapSendService: ZapSendService,
    private val notificationManager: NotificationManager,
    private val configStore: ConfigStore,
) : ViewModel() {
    val profiles: StateFlow<Map<String, FeedProfile>> = nostrService.profiles
    val defaultZapSats: Int get() = configStore.config.value.defaultZapAmount.coerceAtLeast(1)

    fun hex(npub: String): String? = nostrService.npubToHex(npub)

    /** So the pill can tell whether the artist takes zaps (a lightning address on their profile). */
    fun loadProfile(hex: String) = nostrService.fetchMissingProfiles(listOf(hex))

    fun zap(hex: String, amount: Int = defaultZapSats) {
        viewModelScope.launch {
            // The zap pill reports the result (docs/pills.md).
            notificationManager.zapping(com.nostrvault.ui.screens.feed.zapRecipientName(profiles.value, hex), amount) {
                zapSendService.zapNote(noteId = "", notePubkey = hex, amountSats = amount)
            }
        }
    }
}

/** Whether [profile] can be zapped: a lightning address (lud16) or LNURL (lud06). iOS: ArtistZapPill.lightningAddress. */
internal fun takesZaps(profile: FeedProfile?): Boolean =
    !profile?.lud16.isNullOrBlank() || !profile?.lud06.isNullOrBlank()
