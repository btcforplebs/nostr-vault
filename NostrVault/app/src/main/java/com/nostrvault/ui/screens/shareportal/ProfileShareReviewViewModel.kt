package com.nostrvault.ui.screens.shareportal

import androidx.lifecycle.ViewModel
import com.nostrvault.data.local.ConfigStore
import com.nostrvault.data.model.FeedProfile
import com.nostrvault.service.FeedService
import com.nostrvault.service.NostrService
import com.nostrvault.service.isReadOnlyAccount
import com.nostrvault.service.shareportal.handlers.ProfileShareHandler
import com.nostrvault.shareportal.ShareIntent
import com.nostrvault.ui.notification.NotificationManager
import dagger.hilt.android.lifecycle.HiltViewModel
import kotlinx.coroutines.flow.StateFlow
import javax.inject.Inject

/** The Profile review card's half: who the share names, and Follow / Block through [ProfileShareHandler]. */
@HiltViewModel
class ProfileShareReviewViewModel @Inject constructor(
    private val feedService: FeedService,
    private val nostrService: NostrService,
    private val configStore: ConfigStore,
    private val notificationManager: NotificationManager,
) : ViewModel() {
    val profiles: StateFlow<Map<String, FeedProfile>> = nostrService.profiles
    val followed: StateFlow<List<String>> = feedService.followedPubkeys

    fun people(intent: ShareIntent): List<String> = ProfileShareHandler.people(intent).also {
        if (it.isNotEmpty()) nostrService.fetchMissingProfiles(it)
    }

    fun activeHex(): String = configStore.activeAccountHexPubkey.value
    fun canSign(): Boolean = !nostrService.isReadOnlyAccount()
    fun isBlocked(hex: String): Boolean = feedService.isBlocked(hex)

    /** Follows; [onDone] closes the card unless it couldn't be done. */
    fun follow(hex: String, onDone: () -> Unit, onFailed: (String) -> Unit) {
        when (val outcome = ProfileShareHandler.follow(feedService, hex)) {
            ProfileShareHandler.FollowOutcome.Done -> onDone()
            ProfileShareHandler.FollowOutcome.Queued -> {
                notificationManager.showToast("Will follow once your follow list loads")
                onDone()
            }
            is ProfileShareHandler.FollowOutcome.Failed -> onFailed(outcome.why)
        }
    }

    fun block(hex: String, name: String, onDone: () -> Unit) {
        ProfileShareHandler.block(feedService, hex)
        notificationManager.showToast("Blocked $name")
        onDone()
    }
}
