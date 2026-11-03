package com.nostrvault.ui.screens.shareportal

import androidx.lifecycle.ViewModel
import androidx.lifecycle.viewModelScope
import com.nostrvault.data.local.ConfigStore
import com.nostrvault.service.BookmarkService
import com.nostrvault.service.NostrService
import com.nostrvault.service.shareportal.handlers.BookmarkShareHandler
import com.nostrvault.ui.notification.NotificationManager
import dagger.hilt.android.lifecycle.HiltViewModel
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.asStateFlow
import kotlinx.coroutines.launch
import javax.inject.Inject

/** The Save for later review card's half: one Save through [BookmarkShareHandler], what happened said on the card. */
@HiltViewModel
class BookmarkShareReviewViewModel @Inject constructor(
    private val nostrService: NostrService,
    private val configStore: ConfigStore,
    private val bookmarkService: BookmarkService,
    private val notificationManager: NotificationManager,
) : ViewModel() {
    private val _saving = MutableStateFlow(false)
    val saving: StateFlow<Boolean> = _saving.asStateFlow()
    private val _message = MutableStateFlow<String?>(null)
    val message: StateFlow<String?> = _message.asStateFlow()

    val canSign: Boolean get() = bookmarkService.canSign

    fun save(url: String, privately: Boolean, onDone: () -> Unit) {
        if (_saving.value) return
        _saving.value = true
        _message.value = null
        viewModelScope.launch {
            val outcome = BookmarkShareHandler.save(nostrService, configStore, bookmarkService, url, privately)
            _saving.value = false
            when (outcome) {
                is BookmarkShareHandler.Outcome.Saved -> {
                    notificationManager.showToast(if (outcome.privately) "Saved privately" else "Saved for later")
                    onDone()
                }
                BookmarkShareHandler.Outcome.AlreadyPublic -> { notificationManager.showToast("Already in your bookmarks"); onDone() }
                BookmarkShareHandler.Outcome.AlreadyPrivate -> { notificationManager.showToast("Already in your private bookmarks"); onDone() }
                BookmarkShareHandler.Outcome.MayStillGoOut -> _message.value =
                    "Your signer hasn't answered yet, so this may still go out. Check Bookmarks before saving it again."
                is BookmarkShareHandler.Outcome.Failed -> _message.value = "Not saved: ${outcome.why ?: "your relays didn't answer"}."
            }
        }
    }
}
