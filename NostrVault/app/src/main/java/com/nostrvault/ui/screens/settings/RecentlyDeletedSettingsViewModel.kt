package com.nostrvault.ui.screens.settings

import androidx.lifecycle.ViewModel
import androidx.lifecycle.viewModelScope
import com.nostrvault.data.local.ConfigStore
import com.nostrvault.service.FeedService
import com.nostrvault.service.NostrService
import com.nostrvault.service.deleted.DeletedPost
import com.nostrvault.service.deleted.DeletedPostsStore
import com.nostrvault.service.undelete
import dagger.hilt.android.lifecycle.HiltViewModel
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.SharingStarted
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.asStateFlow
import kotlinx.coroutines.flow.combine
import kotlinx.coroutines.flow.flowOn
import kotlinx.coroutines.flow.stateIn
import kotlinx.coroutines.launch
import javax.inject.Inject

/** Settings > Recently Deleted (iOS RecentlyDeletedSettingsView). */
@HiltViewModel
class RecentlyDeletedSettingsViewModel @Inject constructor(
    private val store: DeletedPostsStore,
    private val nostrService: NostrService,
    private val feedService: FeedService,
    configStore: ConfigStore,
) : ViewModel() {

    /** The active account's saved posts, most recently deleted first. */
    val posts: StateFlow<List<DeletedPost>> =
        combine(store.changes, configStore.activeAccountHexPubkey) { _, account ->
            if (account.isEmpty()) emptyList() else store.posts(account)
        }
            .flowOn(Dispatchers.IO)
            .stateIn(viewModelScope, SharingStarted.WhileSubscribed(5_000), emptyList())

    private val _restoringId = MutableStateFlow<String?>(null)
    val restoringId: StateFlow<String?> = _restoringId.asStateFlow()

    /** One line for the last un-delete, or null. */
    private val _message = MutableStateFlow<String?>(null)
    val message: StateFlow<String?> = _message.asStateFlow()

    fun undelete(post: DeletedPost) {
        if (_restoringId.value != null) return
        _restoringId.value = post.id
        viewModelScope.launch {
            val posted = nostrService.undelete(post, store, feedService)
            _restoringId.value = null
            _message.value = if (posted) {
                "Posted again."
            } else {
                "Couldn't post it again: it wasn't signed, or no relay took it. The copy is kept here."
            }
        }
    }

    fun deleteForever(post: DeletedPost) {
        viewModelScope.launch(Dispatchers.IO) { store.remove(post.id, post.pubkey) }
    }
}
