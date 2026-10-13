package com.nostrvault.ui.screens

import androidx.compose.foundation.layout.*
import androidx.compose.material3.*
import androidx.compose.runtime.*
import androidx.lifecycle.SavedStateHandle
import androidx.lifecycle.viewModelScope
import com.nostrvault.data.local.ConfigStore
import com.nostrvault.service.FeedService
import com.nostrvault.service.InterestListService
import com.nostrvault.service.NostrService
import com.nostrvault.service.ZapSendService
import com.nostrvault.ui.navigation.HashtagLink
import com.nostrvault.ui.theme.*
import dagger.hilt.android.lifecycle.HiltViewModel
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.SharingStarted
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.asStateFlow
import kotlinx.coroutines.flow.flowOf
import kotlinx.coroutines.flow.map
import kotlinx.coroutines.flow.stateIn
import kotlinx.coroutines.launch
import javax.inject.Inject

/** The hashtag sheet: one tag, with its Follow button. */
@HiltViewModel
class HashtagFeedViewModel @Inject constructor(
    savedStateHandle: SavedStateHandle,
    nostrService: NostrService,
    configStore: ConfigStore,
    feedService: FeedService,
    zapSendService: ZapSendService,
    notificationManager: com.nostrvault.ui.notification.NotificationManager,
    private val interestListService: InterestListService,
) : HashtagNotesViewModel(nostrService, configStore, feedService, zapSendService, notificationManager) {

    val tag: String = HashtagLink.normalize(savedStateHandle.get<String>("tag").orEmpty()).orEmpty()

    /** Followed hashtags: the account's interest list (kind 10015), the one other Nostr apps read. */
    val isFollowingTag: StateFlow<Boolean> = interestListService.hashtags
        .map { tag in it }
        .stateIn(viewModelScope, SharingStarted.Eagerly, interestListService.isFollowing(tag))

    private val _followSaving = MutableStateFlow(false)
    val followSaving: StateFlow<Boolean> = _followSaving.asStateFlow()

    private val _followFailed = MutableStateFlow(false)
    val followFailed: StateFlow<Boolean> = _followFailed.asStateFlow()

    init {
        interestListService.refreshIfNeeded()
        // The follow list and the trust graph can arrive after the screen opens.
        observe(flowOf(listOfNotNull(tag.takeIf { it.isNotEmpty() })))
    }

    fun toggleFollow() {
        if (tag.isEmpty() || _followSaving.value) return
        val follow = !isFollowingTag.value
        _followSaving.value = true
        viewModelScope.launch {
            try {
                if (!interestListService.setFollowing(tag, follow)) _followFailed.value = true
            } finally {
                _followSaving.value = false
            }
        }
    }

    fun clearFollowFailed() { _followFailed.value = false }
}
