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
import com.nostrvault.service.ZapSendService
import dagger.hilt.android.lifecycle.HiltViewModel
import kotlinx.coroutines.ExperimentalCoroutinesApi
import kotlinx.coroutines.delay
import kotlinx.coroutines.flow.*
import kotlinx.coroutines.launch
import javax.inject.Inject

/**
 * ViewModel for a user's profile screen — ports iOS ProfileView.
 * Loads profile metadata, the author's notes/reposts/long-form, tagged notes,
 * follower/following counts, and drives a persistent [NostrService.ProfileStream]
 * with infinite-scroll pagination.
 */
enum class ProfileSection(val displayName: String) {
    NOTES("Notes"),
    MEDIA("Media"),
    REPLIES("Replies"),
    TAGGED("Tagged"),
}

/** Per-tab counts shown next to the section labels. */
data class ProfileCounts(
    val notes: Int = 0,
    val media: Int = 0,
    val replies: Int = 0,
    val tagged: Int = 0,
)

@OptIn(ExperimentalCoroutinesApi::class)
@HiltViewModel
class ProfileViewModel @Inject constructor(
    savedStateHandle: SavedStateHandle,
    private val nostrService: NostrService,
    private val feedService: FeedService,
    private val zapSendService: ZapSendService,
    private val configStore: ConfigStore,
) : ViewModel() {

    companion object {
        /** Default zap amount (sats) — no per-user setting on Android yet. */
        const val DEFAULT_ZAP_SATS = 21
    }

    private val _pubkey = MutableStateFlow(savedStateHandle.get<String>("pubkey") ?: "")
    val pubkey: String get() = _pubkey.value

    val profile: StateFlow<FeedProfile?> = _pubkey.flatMapLatest { pk ->
        nostrService.profiles.map { it[pk] }
    }.stateIn(viewModelScope, SharingStarted.WhileSubscribed(5000), null)

    private val _profileNotes = MutableStateFlow<List<FeedNote>>(emptyList())
    val profileNotes: StateFlow<List<FeedNote>> = _profileNotes.asStateFlow()

    private val _taggedNotes = MutableStateFlow<List<FeedNote>>(emptyList())
    val taggedNotes: StateFlow<List<FeedNote>> = _taggedNotes.asStateFlow()

    val noteStats: StateFlow<Map<String, NoteStats>> = feedService.noteStats
    val likedEventIds: StateFlow<Set<String>> = feedService.likedEventIds
    val repostedEventIds: StateFlow<Set<String>> = feedService.repostedEventIds
    val profiles: StateFlow<Map<String, FeedProfile>> = nostrService.profiles

    private val _selectedSection = MutableStateFlow(ProfileSection.NOTES)
    val selectedSection: StateFlow<ProfileSection> = _selectedSection.asStateFlow()

    private val _isFollowing = MutableStateFlow(false)
    val isFollowing: StateFlow<Boolean> = _isFollowing.asStateFlow()

    private val _isOwnProfile = MutableStateFlow(false)
    val isOwnProfile: StateFlow<Boolean> = _isOwnProfile.asStateFlow()

    private val _followsMe = MutableStateFlow(false)
    val followsMe: StateFlow<Boolean> = _followsMe.asStateFlow()

    private val _isBlocked = MutableStateFlow(false)
    val isBlocked: StateFlow<Boolean> = _isBlocked.asStateFlow()

    /** null until known → UI shows "∞" for other users (mirrors iOS). */
    private val _followersCount = MutableStateFlow<Int?>(null)
    val followersCount: StateFlow<Int?> = _followersCount.asStateFlow()

    private val _followingCount = MutableStateFlow<Int?>(null)
    val followingCount: StateFlow<Int?> = _followingCount.asStateFlow()

    private val _isLoading = MutableStateFlow(true)
    val isLoading: StateFlow<Boolean> = _isLoading.asStateFlow()

    private val _isLoadingOlder = MutableStateFlow(false)
    val isLoadingOlder: StateFlow<Boolean> = _isLoadingOlder.asStateFlow()

    private val _hasMoreNotes = MutableStateFlow(true)
    val hasMoreNotes: StateFlow<Boolean> = _hasMoreNotes.asStateFlow()

    private val _hasMoreTagged = MutableStateFlow(true)
    val hasMoreTagged: StateFlow<Boolean> = _hasMoreTagged.asStateFlow()

    /** Transient user-facing message (zap / block result). */
    private val _toast = MutableStateFlow<String?>(null)
    val toast: StateFlow<String?> = _toast.asStateFlow()

    val defaultZapSats: Int = DEFAULT_ZAP_SATS

    val filteredNotes: StateFlow<List<FeedNote>> = combine(
        _profileNotes,
        _taggedNotes,
        _selectedSection,
    ) { notes, tagged, section ->
        when (section) {
            // Matches iOS ProfileView sections: reposts appear in Notes (no
            // dedicated Reposts tab), replies in Replies.
            ProfileSection.NOTES -> notes.filter { !it.isReply }
            ProfileSection.MEDIA -> notes.filter { it.mediaURLs.isNotEmpty() && !it.isReply && it.repostedBy == null }
            ProfileSection.REPLIES -> notes.filter { it.isReply && it.repostedBy == null }
            ProfileSection.TAGGED -> tagged.filter { it.pubkey != _pubkey.value }
        }
    }.stateIn(viewModelScope, SharingStarted.WhileSubscribed(5000), emptyList())

    val counts: StateFlow<ProfileCounts> = combine(
        _profileNotes,
        _taggedNotes,
    ) { notes, tagged ->
        ProfileCounts(
            notes = notes.count { !it.isReply },
            media = notes.count { it.mediaURLs.isNotEmpty() && !it.isReply && it.repostedBy == null },
            replies = notes.count { it.isReply && it.repostedBy == null },
            tagged = tagged.count { it.pubkey != _pubkey.value },
        )
    }.stateIn(viewModelScope, SharingStarted.WhileSubscribed(5000), ProfileCounts())

    // Dedup + stream state
    private val seenNoteIds = mutableSetOf<String>()
    private val seenTaggedIds = mutableSetOf<String>()
    private val followerPubkeys = mutableSetOf<String>()
    private var stream: NostrService.ProfileStream? = null

    init {
        if (_pubkey.value.isNotEmpty()) {
            loadProfile()
        }
    }

    fun setPubkey(pubkey: String) {
        if (_pubkey.value != pubkey && pubkey.isNotEmpty()) {
            stream?.close(); stream = null
            _pubkey.value = pubkey
            // Reset per-profile state
            seenNoteIds.clear(); seenTaggedIds.clear(); followerPubkeys.clear()
            _profileNotes.value = emptyList()
            _taggedNotes.value = emptyList()
            _followersCount.value = null
            _followingCount.value = null
            _followsMe.value = false
            _hasMoreNotes.value = true
            _hasMoreTagged.value = true
            _selectedSection.value = ProfileSection.NOTES
            loadProfile()
        }
    }

    private fun loadProfile() {
        val pk = _pubkey.value
        if (pk.isEmpty()) return

        viewModelScope.launch {
            _isLoading.value = true
            val own = pk == configStore.activeAccountHexPubkey.value
            _isOwnProfile.value = own
            _isFollowing.value = feedService.isFollowing(pk)
            _isBlocked.value = feedService.isBlocked(pk)

            // Own following count is known instantly from our contact list.
            if (own) {
                _followingCount.value = feedService.followedPubkeys.value.count { it != pk }
            }

            // Fetch metadata if missing.
            if (nostrService.profiles.value[pk] == null) {
                nostrService.fetchMissingProfiles(listOf(pk))
            }

            // Seed instantly from cached feed notes (iOS parity).
            val cached = feedService.notes.value.filter { it.pubkey == pk }
            if (cached.isNotEmpty()) {
                cached.forEach { seenNoteIds.add(it.id) }
                _profileNotes.value = cached.sortedByDescending { it.createdAt }
            }

            startStream(pk)

            // Fallback: stop the spinner after 10s even if no EOSE arrives.
            launch {
                delay(10_000)
                if (_pubkey.value == pk) _isLoading.value = false
            }
        }
    }

    private fun startStream(pk: String) {
        val s = nostrService.profileStream(pk)
        s.onNote = { note -> addNote(note) }
        s.onTagged = { note -> addTagged(note) }
        s.onContacts = { following, followsMe ->
            if (!_isOwnProfile.value) _followingCount.value = following
            _followsMe.value = followsMe
        }
        s.onFollower = { followerPk ->
            if (followerPubkeys.add(followerPk)) {
                _followersCount.value = followerPubkeys.size
            }
        }
        s.onEose = { subId ->
            // Initial combined REQ finished → drop the spinner. Pagination uses
            // its own timed checks (see loadOlder).
            if (subId.startsWith("profile-")) _isLoading.value = false
        }
        stream = s
        s.start()
    }

    @Synchronized
    private fun addNote(note: FeedNote) {
        // Authored by this user OR reposted by this user (a kind-6 repost resolves
        // to pubkey = original author, repostedBy = this profile).
        val isOwnRepost = note.repostedBy == _pubkey.value
        if (note.pubkey != _pubkey.value && !isOwnRepost) return
        if (!seenNoteIds.add(note.id)) return
        // Reposts show the ORIGINAL author — fetch their metadata if missing.
        if (isOwnRepost && nostrService.profiles.value[note.pubkey] == null) {
            nostrService.fetchMissingProfiles(listOf(note.pubkey))
        }
        _profileNotes.value = (_profileNotes.value + note).sortedByDescending { it.createdAt }
        feedService.cacheNote(note)
    }

    @Synchronized
    private fun addTagged(note: FeedNote) {
        if (!seenTaggedIds.add(note.id)) return
        if (nostrService.profiles.value[note.pubkey] == null) {
            nostrService.fetchMissingProfiles(listOf(note.pubkey))
        }
        _taggedNotes.value = (_taggedNotes.value + note).sortedByDescending { it.createdAt }
        feedService.cacheNote(note)
    }

    /** Infinite-scroll: page older notes (or tagged) on the open stream sockets. */
    fun loadOlder() {
        val s = stream ?: return
        if (_isLoadingOlder.value) return
        if (_selectedSection.value == ProfileSection.TAGGED) {
            if (!_hasMoreTagged.value) return
            val oldest = _taggedNotes.value.lastOrNull() ?: return
            _isLoadingOlder.value = true
            val before = _taggedNotes.value.size
            s.loadOlderTagged(oldest.createdAt.time / 1000)
            viewModelScope.launch {
                delay(5000)
                if (_taggedNotes.value.size == before) _hasMoreTagged.value = false
                _isLoadingOlder.value = false
            }
        } else {
            if (!_hasMoreNotes.value) return
            val oldest = _profileNotes.value.lastOrNull() ?: return
            _isLoadingOlder.value = true
            val before = _profileNotes.value.size
            s.loadOlder(oldest.createdAt.time / 1000)
            viewModelScope.launch {
                delay(5000)
                if (_profileNotes.value.size == before) _hasMoreNotes.value = false
                _isLoadingOlder.value = false
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
            if (_isFollowing.value) feedService.unfollowPubkey(pk) else feedService.followPubkey(pk)
            _isFollowing.value = !_isFollowing.value
        }
    }

    fun toggleBlock() {
        val pk = _pubkey.value
        if (pk.isEmpty()) return
        if (_isBlocked.value) feedService.unblockUser(pk) else feedService.blockUser(pk)
        _isBlocked.value = !_isBlocked.value
    }

    /** True when a NWC wallet is configured and the profile has a lightning address. */
    val hasWallet: Boolean get() = !configStore.config.value.nwcURI.isNullOrBlank()

    /** Resolved lightning address (LUD-16 or LUD-06), or null. Mirrors iOS. */
    val lightningAddress: String?
        get() {
            val p = profile.value ?: return null
            p.lud06?.takeIf { it.isNotBlank() }?.let { return "lnurl:$it" }
            p.lud16?.takeIf { it.isNotBlank() }?.let { return it }
            return null
        }

    val website: String? get() = profile.value?.website?.takeIf { it.isNotBlank() }

    /** npub (bech32) for the copy row; null if encoding fails. */
    val npub: String? get() = nostrService.hexToNpub(_pubkey.value)

    fun zap() {
        val pk = _pubkey.value
        if (pk.isEmpty()) return
        viewModelScope.launch {
            val result = zapSendService.zapNote(pk, pk, DEFAULT_ZAP_SATS)
            _toast.value = result.fold(
                onSuccess = { "Zapped $DEFAULT_ZAP_SATS sats ⚡️" },
                onFailure = { "Zap failed: ${it.message ?: "unknown error"}" },
            )
        }
    }

    fun clearToast() { _toast.value = null }

    /** Zap a post (default amount) — feedback via [toast]. */
    fun zapNote(noteId: String, notePubkey: String) {
        viewModelScope.launch {
            val result = zapSendService.zapNote(noteId, notePubkey, DEFAULT_ZAP_SATS)
            _toast.value = result.fold(
                onSuccess = { "Zapped $DEFAULT_ZAP_SATS sats ⚡️" },
                onFailure = { "Zap failed: ${it.message ?: "unknown error"}" },
            )
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
    fun isReposted(noteId: String): Boolean = repostedEventIds.value.contains(noteId)

    // ── Quoted note resolution (embedded nostr:note1/nevent1 previews) ──

    val quotedNotesCache: StateFlow<Map<String, FeedNote>> = feedService.quotedNotes

    fun quotedNoteFor(identifier: String): FeedNote? = feedService.quotedNoteFor(identifier)

    fun fetchMissingQuotedNotes(notes: List<FeedNote>) =
        feedService.fetchMissingQuotedNotes(notes)

    fun fetchMissingQuotedProfiles(notes: List<FeedNote>) =
        feedService.fetchMissingQuotedProfiles(notes)

    override fun onCleared() {
        super.onCleared()
        stream?.close()
        stream = null
    }
}
