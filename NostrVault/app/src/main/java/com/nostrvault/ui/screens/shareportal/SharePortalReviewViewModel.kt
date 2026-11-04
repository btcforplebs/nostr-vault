package com.nostrvault.ui.screens.shareportal

import android.content.Context
import androidx.lifecycle.ViewModel
import androidx.lifecycle.viewModelScope
import com.nostrvault.data.local.ConfigStore
import com.nostrvault.service.shareportal.SharePortalRouter
import com.nostrvault.service.shareportal.handlers.HighlightShareHandler
import com.nostrvault.service.shareportal.handlers.ShareHandler
import com.nostrvault.shareportal.ShareIntent
import com.nostrvault.shareportal.ShareQueue
import com.nostrvault.ui.notification.NotificationManager
import dagger.hilt.android.lifecycle.HiltViewModel
import dagger.hilt.android.qualifiers.ApplicationContext
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.SharingStarted
import kotlinx.coroutines.flow.asStateFlow
import kotlinx.coroutines.flow.map
import kotlinx.coroutines.flow.stateIn
import kotlinx.coroutines.launch
import kotlinx.coroutines.withContext
import javax.inject.Inject

/**
 * Claims what the share sheet queued and walks the review cards oldest first.
 * Claimed intents stay on disk until published or dismissed, so leaving for
 * Amber and coming back (or the process dying) finds the same card. Twin:
 * SharePortalInbox.swift.
 */
@HiltViewModel
class SharePortalReviewViewModel @Inject constructor(
    @ApplicationContext context: Context,
    val router: SharePortalRouter,
    private val configStore: ConfigStore,
    private val notificationManager: NotificationManager,
) : ViewModel() {
    private val queue = ShareQueue.forApp(context)

    private val _items = MutableStateFlow<List<ShareIntent>>(emptyList())
    val items: StateFlow<List<ShareIntent>> = _items.asStateFlow()

    private val _busy = MutableStateFlow(false)
    val busy: StateFlow<Boolean> = _busy.asStateFlow()

    /** The account that would sign right now, so the card can ask for a switch first. */
    val activeNpub: StateFlow<String> = configStore.config
        .map { it.activeOrOwnerNpub() }
        .stateIn(viewModelScope, SharingStarted.Eagerly, configStore.config.value.activeOrOwnerNpub())

    init { refresh() }

    fun refresh() {
        viewModelScope.launch {
            _items.value = withContext(Dispatchers.IO) {
                queue.claimAll()
                queue.claimed()
            }
        }
    }

    fun handler(intent: ShareIntent): ShareHandler = router.handler(intent.action)

    fun dismiss(intent: ShareIntent) {
        viewModelScope.launch {
            withContext(Dispatchers.IO) { queue.finish(intent.id) }
            _items.value = _items.value.filterNot { it.id == intent.id }
        }
    }

    fun switchAccount(npub: String) {
        viewModelScope.launch { configStore.switchActiveAccount(npub) }
    }

    /** The claimed copy of one of [intent]'s files. */
    fun claimedFile(intent: ShareIntent, file: com.nostrvault.shareportal.ShareFile) = queue.claimedFile(intent, file)

    /**
     * Runs one lane A publish or save off the card: [work] returns the toast
     * to show and closes the card, or an error to show and keeps it.
     */
    fun runAction(intent: ShareIntent, after: () -> Unit = {}, work: suspend () -> LaneAResult) {
        if (_busy.value) return
        _busy.value = true
        viewModelScope.launch {
            when (val r = runCatching { work() }.getOrElse { LaneAResult.Failed("Something went wrong") }) {
                is LaneAResult.Done -> { notificationManager.showToast(r.message); dismiss(intent); after() }
                is LaneAResult.Failed -> notificationManager.showError(r.message)
            }
            _busy.value = false
        }
    }

    fun publishHighlight(intent: ShareIntent, passage: String, comment: String, pageLink: String? = null) {
        if (_busy.value) return
        _busy.value = true
        viewModelScope.launch {
            when (router.highlight.publish(intent, passage, comment, pageLink)) {
                HighlightShareHandler.Outcome.Published -> {
                    notificationManager.showToast("Highlight published")
                    dismiss(intent)
                }
                HighlightShareHandler.Outcome.WrongAccount -> notificationManager.showError("Switch to that account first")
                HighlightShareHandler.Outcome.NotSigned -> notificationManager.showError("Highlight not signed")
                HighlightShareHandler.Outcome.Empty -> Unit
            }
            _busy.value = false
        }
    }
}
