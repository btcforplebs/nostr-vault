package com.nostrvault.ui.screens.profile

import androidx.lifecycle.SavedStateHandle
import androidx.lifecycle.ViewModel
import androidx.lifecycle.viewModelScope
import com.nostrvault.data.local.ConfigStore
import com.nostrvault.data.model.FeedNote
import com.nostrvault.data.model.FeedProfile
import com.nostrvault.data.model.NoteStats
import com.nostrvault.service.FeedService
import com.nostrvault.service.NostrService
import dagger.hilt.android.lifecycle.HiltViewModel
import kotlinx.coroutines.ExperimentalCoroutinesApi
import kotlinx.coroutines.delay
import kotlinx.coroutines.flow.*
import kotlinx.coroutines.launch
import javax.inject.Inject

/**
 * ViewModel for a user's profile screen.
 * Loads profile data, notes, and follow state.
 */
enum class ProfileSection(val displayName: String) {
    NOTES("Notes"),
    MEDIA("Media"),
    REPLIES("Replies"),
}

@OptIn(ExperimentalCoroutinesApi::class)
@HiltViewModel
class ProfileViewModel @Inject constructor(
    savedStateHandle: SavedStateHandle,
    private val nostrService: NostrService,
    private val feedService: FeedService,
    private val configStore: ConfigStore,
) : ViewModel() {

    private val _pubkey = MutableStateFlow(savedStateHandle.get<String>("pubkey") ?: "")
    val pubkey: String get() = _pubkey.value

    val profile: StateFlow<FeedProfile?> = _pubkey.flatMapLatest { pk ->
        nostrService.profiles.map { it[pk] }
    }.stateIn(viewModelScope, SharingStarted.WhileSubscribed(5000), null)

    private val _profileNotes = MutableStateFlow<List<FeedNote>>(emptyList())
    val profileNotes: StateFlow<List<FeedNote>> = _profileNotes.asStateFlow()

    val noteStats: StateFlow<Map<String, NoteStats>> = feedService.noteStats
    val likedEventIds: StateFlow<Set<String>> = feedService.likedEventIds
    val profiles: StateFlow<Map<String, FeedProfile>> = nostrService.profiles

    private val _selectedSection = MutableStateFlow(ProfileSection.NOTES)
    val selectedSection: StateFlow<ProfileSection> = _selectedSection.asStateFlow()

    private val _isFollowing = MutableStateFlow(false)
    val isFollowing: StateFlow<Boolean> = _isFollowing.asStateFlow()

    private val _isOwnProfile = MutableStateFlow(false)
    val isOwnProfile: StateFlow<Boolean> = _isOwnProfile.asStateFlow()

    private val _followersCount = MutableStateFlow(0)
    val followersCount: StateFlow<Int> = _followersCount.asStateFlow()

    private val _followingCount = MutableStateFlow(0)
    val followingCount: StateFlow<Int> = _followingCount.asStateFlow()

    private val _isLoading = MutableStateFlow(true)
    val isLoading: StateFlow<Boolean> = _isLoading.asStateFlow()

    val filteredNotes: StateFlow<List<FeedNote>> = combine(
        _profileNotes,
        _selectedSection,
    ) { notes, section ->
        when (section) {
            ProfileSection.NOTES -> notes.filter { !it.isReply }
            ProfileSection.MEDIA -> notes.filter { it.mediaURLs.isNotEmpty() && !it.isReply }
            ProfileSection.REPLIES -> notes.filter { it.isReply }
        }
    }.stateIn(viewModelScope, SharingStarted.WhileSubscribed(5000), emptyList())

    init {
        if (_pubkey.value.isNotEmpty()) {
            loadProfile()
        }
    }

    fun setPubkey(pubkey: String) {
        if (_pubkey.value != pubkey && pubkey.isNotEmpty()) {
            _pubkey.value = pubkey
            // Clear old notes when switching profiles
            _profileNotes.value = emptyList()
            loadProfile()
        }
    }

    private fun loadProfile() {
        val pk = _pubkey.value
        if (pk.isEmpty()) return

        viewModelScope.launch {
            _isLoading.value = true
            _isOwnProfile.value = pk == configStore.activeAccountHexPubkey.value

            // Fetch profile if not cached
            if (nostrService.profiles.value[pk] == null) {
                nostrService.fetchMissingProfiles(listOf(pk))
            }

            // Check follow state
            _isFollowing.value = feedService.isFollowing(pk)

            // Load notes for this profile
            var notesReceived = false
            nostrService.fetchProfileNotes(pk) { notes ->
                // Only update if we're still loading this same profile
                if (_pubkey.value == pk) {
                    _profileNotes.value = notes.sortedByDescending { it.createdAt }
                    notesReceived = true
                    _isLoading.value = false
                }
            }

            // Fallback timeout: stop loading after 10 seconds if notes never arrive
            launch {
                delay(10000)
                if (!notesReceived && _pubkey.value == pk && _isLoading.value) {
                    _isLoading.value = false
                }
            }
        }
    }

    fun setSection(section: ProfileSection) {
        _selectedSection.value = section
    }

    fun toggleFollow() {
        val pk = _pubkey.value
        if (pk.isEmpty()) return

        viewModelScope.launch {
            if (_isFollowing.value) {
                feedService.unfollowPubkey(pk)
            } else {
                feedService.followPubkey(pk)
            }
            _isFollowing.value = !_isFollowing.value
        }
    }

    fun likeNote(noteId: String) {
        viewModelScope.launch { feedService.likeNote(noteId) }
    }

    fun repostNote(noteId: String) {
        viewModelScope.launch { feedService.repostNote(noteId) }
    }

    fun profileFor(pubkey: String): FeedProfile? = profiles.value[pubkey]
    fun statsFor(noteId: String): NoteStats? = noteStats.value[noteId]
    fun isLiked(noteId: String): Boolean = likedEventIds.value.contains(noteId)

    // ── Quoted note resolution (embedded nostr:note1/nevent1 previews) ──

    val quotedNotesCache: StateFlow<Map<String, FeedNote>> = feedService.parentNotesCache

    fun quotedNoteFor(identifier: String): FeedNote? = feedService.quotedNoteFor(identifier)

    fun fetchMissingQuotedNotes(identifiers: List<String>) =
        feedService.fetchMissingQuotedNotes(identifiers)

    fun fetchMissingQuotedProfiles(identifiers: List<String>) =
        feedService.fetchMissingQuotedProfiles(identifiers)
}
