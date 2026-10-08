package com.nostrvault.ui.screens.profile

import com.nostrvault.ui.components.ZapFlight
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
import kotlinx.coroutines.withTimeoutOrNull
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
    /** This person's kind-6 reposts, kept out of Notes. */
    REPOSTS("Reposts"),
    /** Long-form posts (kind 30023). Shown only when there are some. */
    ARTICLES("Articles"),
    /** Short videos (kind 34236). Shown only when there are some. */
    DIVINES("diVines"),
    /** Wavlake songs. Shown only when the artist is found. */
    MUSIC("Music"),
    TAGGED("Tagged"),
    /** Marketplace listings. Shown only when there are some, or on your own profile. */
    SHOP("Shop"),
    ;

    /** Sections that list notes, and page in older ones as you scroll. */
    val isNoteList: Boolean get() = this == NOTES || this == MEDIA || this == REPLIES || this == REPOSTS || this == TAGGED
}

/** Per-tab counts shown next to the section labels. */
data class ProfileCounts(
    val notes: Int = 0,
    val media: Int = 0,
    val replies: Int = 0,
    val reposts: Int = 0,
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
    private val engagementStore: com.nostrvault.service.ProfileEngagementStore,
    private val blossomService: com.nostrvault.service.BlossomService,
    private val mediaCacheService: com.nostrvault.service.MediaCacheService,
    private val mediaSaveService: com.nostrvault.service.MediaSaveService,
) : ViewModel() {

    /**
     * Likes, reposts, replies, quotes and zap sats under each post, by post
     * id; read with [com.nostrvault.service.ProfileEngagementStore.engagement].
     */
    val engagementLedgers = engagementStore.ledgers

    fun engagementFor(ledgers: Map<String, com.nostrvault.data.model.EngagementLedger>, id: String) =
        engagementStore.engagement(ledgers, id)

    /**
     * Counts for the posts on screen, fetched as they appear. The tagged tab
     * is other people's posts, so it is left out, and the media grid has no
     * buttons to put them on. A repost is counted on the note it reposted.
     */
    fun loadEngagement(force: Boolean = false) {
        // One query at a time: notes stream in, and each new one restarts it
        // with the whole list rather than adding another (iOS cancels too).
        // A pull-to-refresh cut short by a restart keeps its force.
        engagementJob?.cancel()
        val forced = force || engagementForcePending
        engagementForcePending = forced
        engagementJob = viewModelScope.launch {
            if (!forced) delay(ENGAGEMENT_DEBOUNCE_MS)
            // Read after the wait, so a tab switch can't pair the new tab
            // with the old tab's notes.
            val pk = _pubkey.value
            val section = _selectedSection.value
            val notes = filteredNotes.value
            if (pk.isEmpty() || section == ProfileSection.TAGGED || section == ProfileSection.MEDIA || notes.isEmpty()) {
                engagementForcePending = false
                return@launch
            }
            engagementStore.load(notes.map { it.effectiveEventId }, author = pk, force = forced)
            engagementForcePending = false
        }
    }
    private var engagementJob: kotlinx.coroutines.Job? = null
    private var engagementForcePending = false

    companion object {
        /** Posts arriving within this long of each other share one count query. */
        private const val ENGAGEMENT_DEBOUNCE_MS = 300L
        private val COUNT_RELAYS = listOf("wss://relay.damus.io", "wss://relay.primal.net")
    }

    /** The Shop tab: this person's marketplace listings. */
    private val shop = com.nostrvault.service.SellerListingsLoader(viewModelScope, nostrService)
    val shopListings = shop.listings
    val shopLoading = shop.isLoading
    fun reloadShop() = shop.load(_pubkey.value, force = true)

    /** This person's articles, diVines and music, each a tab when they have any. */
    private val extras = ProfileExtrasLoader(viewModelScope, nostrService)
    val articles = extras.articles
    val reels = extras.reels
    val tracks = extras.tracks

    private fun loadExtras(pubkey: String, force: Boolean = false) {
        val config = configStore.config.value
        val relayUp = com.nostrvault.relay.RelayForegroundService.relayStatus.value ==
            com.nostrvault.relay.RelayForegroundService.RelayStatus.RUNNING
        val relays = ProfileExtras.relays(
            ownRelay = config.nostrURL?.takeIf { relayUp },
            feedRelays = config.activeFeedRelays,
            outbox = nostrService.outboxRelays.value[pubkey].orEmpty(),
        )
        extras.load(pubkey, relays, force)
    }

    fun npubToHex(npub: String): String? = nostrService.npubToHex(npub)

    /** Makes [note] resolvable by id for the article reader; returns that id. */
    fun prepareOpen(note: FeedNote): String {
        feedService.cacheNote(note)
        return note.id
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

    /** Pull-to-refresh on your own profile. */
    private val _isRefreshing = MutableStateFlow(false)
    val isRefreshing: StateFlow<Boolean> = _isRefreshing.asStateFlow()

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

    /** The default zap amount from Wallet settings, in sats (iOS `defaultZapSats`). */
    val defaultZapSats: Int get() = configStore.config.value.defaultZapAmount.coerceAtLeast(1)

    val filteredNotes: StateFlow<List<FeedNote>> = combine(
        _profileNotes,
        _taggedNotes,
        _selectedSection,
    ) { notes, tagged, section ->
        when (section) {
            // Matches iOS ProfileView sections: reposts have their own tab,
            // Media is this person's own media whether posted or replied with.
            ProfileSection.NOTES -> notes.filter { !it.isReply && !it.isProfileRepost }
            ProfileSection.MEDIA -> notes.filter { it.isProfileMedia }
            ProfileSection.REPLIES -> notes.filter { it.isReply && !it.isProfileRepost }
            ProfileSection.REPOSTS -> notes.filter { it.isProfileRepost }
            ProfileSection.TAGGED -> tagged.filter { it.pubkey != _pubkey.value }
            // Listings are not notes; the Shop tab reads [shopListings].
            ProfileSection.SHOP -> emptyList()
            // Not notes either; these tabs read [extras].
            ProfileSection.ARTICLES, ProfileSection.DIVINES, ProfileSection.MUSIC -> emptyList()
        }
    }.stateIn(viewModelScope, SharingStarted.WhileSubscribed(5000), emptyList())

    val counts: StateFlow<ProfileCounts> = combine(
        _profileNotes,
        _taggedNotes,
    ) { notes, tagged ->
        ProfileCounts(
            notes = notes.count { !it.isReply && !it.isProfileRepost },
            media = notes.count { it.isProfileMedia },
            replies = notes.count { it.isReply && !it.isProfileRepost },
            reposts = notes.count { it.isProfileRepost },
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
            shop.load(_pubkey.value)
            loadExtras(_pubkey.value)
        }
        // Follow / Unfollow reads the real list, as iOS does: a tap queued
        // until the list loads, or a publish rolled back, shows as it is.
        viewModelScope.launch {
            combine(_pubkey, feedService.followedPubkeys) { pk, followed -> pk.isNotEmpty() && pk in followed }
                .collect { _isFollowing.value = it }
        }
    }

    fun setPubkey(pubkey: String) {
        if (_pubkey.value != pubkey && pubkey.isNotEmpty()) {
            _pubkey.value = pubkey
            resetLoadedState()
            _selectedSection.value = ProfileSection.NOTES
            loadProfile()
            shop.load(pubkey)
            loadExtras(pubkey)
        }
    }

    /** Drops the stream and everything it loaded, for a fresh load. */
    private fun resetLoadedState() {
        stream?.close(); stream = null
        pageToken++
        seenNoteIds.clear(); seenTaggedIds.clear(); followerPubkeys.clear()
        relayFollowerCount = null
        vertexFollowerCount = null
        _profileNotes.value = emptyList()
        _taggedNotes.value = emptyList()
        _followersCount.value = null
        ownLedgerLoaded = false
        _followingCount.value = null
        _followsMe.value = false
        _hasMoreNotes.value = true
        _hasMoreTagged.value = true
        _isLoadingOlder.value = false
    }

    /**
     * Pull-to-refresh, in place: a new stream adds what is new while the
     * notes, counts and tabs on screen stay until something replaces them,
     * so the page never blanks and refills. Metadata is fetched again.
     * iOS: ProfileView.refreshProfile().
     */
    fun refresh() {
        val pk = _pubkey.value
        if (pk.isEmpty() || _isRefreshing.value) return
        _isRefreshing.value = true
        _isLoading.value = true
        // A page of older notes in flight dies with the old stream.
        stream?.close(); stream = null
        pageToken++
        _isLoadingOlder.value = false
        nostrService.fetchMissingProfiles(listOf(pk), force = true)
        loadEngagement(force = true)
        loadProfile()
        shop.load(pk, force = true)
        loadExtras(pk, force = true)
        viewModelScope.launch {
            // Done once the first page is in (the spinner the load drives
            // drops on EOSE), or after a few seconds regardless.
            withTimeoutOrNull(8_000) { _isLoading.first { !it } }
            _isRefreshing.value = false
        }
    }

    /** Set once your own follower ledger supplied the FOLLOWERS count. */
    @Volatile private var ownLedgerLoaded = false

    /** Bumped by each load so an earlier load's fallback can't end a later one. */
    private var loadToken = 0

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
                // Your followers come from the relay's ledger, which is complete
                // (spam left out); relay samples would cap at a page.
                launch {
                    val ledger = kotlinx.coroutines.withContext(kotlinx.coroutines.Dispatchers.IO) {
                        com.nostrvault.data.model.FollowerSnapshot.parse(com.nostrvault.relay.HavenBridge.getFollowers(pk))
                    }
                    if (ledger != null && _pubkey.value == pk) {
                        ownLedgerLoaded = true
                        if (vertexFollowerCount == null) _followersCount.value = ledger.current.size
                    }
                }
            }

            fetchVertexFollowerCount(pk)
            if (!own) fetchFollowerCount(pk)

            // Fetch metadata if missing.
            if (nostrService.profiles.value[pk] == null) {
                nostrService.fetchMissingProfiles(listOf(pk))
            }

            // Seed instantly from cached feed notes (iOS parity).
            val cached = feedService.notes.value.filter { it.pubkey == pk }
            // Merged, not assigned: a refresh keeps what the relays already
            // loaded (their notes are in seenNoteIds, so they won't come back).
            if (cached.isNotEmpty()) mergeNotes(cached)

            startStream(pk)

            // Fallback: stop the spinner after 10s even if no EOSE arrives —
            // unless a later load (a refresh) has started since.
            val token = ++loadToken
            launch {
                delay(10_000)
                if (_pubkey.value == pk && token == loadToken) _isLoading.value = false
            }
        }
    }

    /** Largest NIP-45 COUNT any relay gave for this profile's followers. */
    @Volatile private var relayFollowerCount: Int? = null

    /** Vertex's count, the one npub.world shows. Once it answers, it's the one shown. */
    @Volatile private var vertexFollowerCount: Int? = null

    /**
     * Vertex counts follow lists from across Nostr, once per follower, so
     * its answer replaces the ledger, relay COUNTs and streamed sample, on
     * your profile too. Port of iOS ProfileView.displayedFollowersCount.
     */
    private fun fetchVertexFollowerCount(pk: String) {
        viewModelScope.launch {
            val count = nostrService.fetchVertexFollowerCount(pk) ?: return@launch
            synchronized(this@ProfileViewModel) {
                if (_pubkey.value != pk) return@launch
                vertexFollowerCount = count
                _followersCount.value = count
            }
        }
    }

    /**
     * The streamed kind 3s stop at a page per relay, so they undercount anyone
     * with more followers. Relays that answer NIP-45 COUNT give the full
     * number; the largest single answer wins, since relays hold overlapping
     * subsets and adding them would double-count. Port of iOS
     * ProfileView.fetchFollowerCount.
     */
    private fun fetchFollowerCount(pk: String) {
        // damus and primal answer COUNT; most other popular relays refuse it.
        val relays = (COUNT_RELAYS + configStore.config.value.readRelays.take(3))
            .distinctBy { it.trim().trimEnd('/').lowercase() }
        val filter = mapOf("kinds" to listOf(3), "#p" to listOf(pk))
        for (url in relays) viewModelScope.launch {
            val count = nostrService.countEvents(url, filter) ?: return@launch
            synchronized(this@ProfileViewModel) {
                if (_pubkey.value != pk) return@launch
                val best = maxOf(relayFollowerCount ?: 0, count)
                relayFollowerCount = best
                if (vertexFollowerCount == null) _followersCount.value = maxOf(best, _followersCount.value ?: 0)
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
            // Your ledger's count is exact; the relay sample only stands in
            // when the ledger can't be read.
            synchronized(this@ProfileViewModel) {
                if (followerPubkeys.add(followerPk) && !ownLedgerLoaded && vertexFollowerCount == null) {
                    _followersCount.value = maxOf(followerPubkeys.size, relayFollowerCount ?: 0)
                }
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
    private fun mergeNotes(notes: List<FeedNote>) {
        val fresh = notes.filter { seenNoteIds.add(it.id) }
        if (fresh.isEmpty()) return
        _profileNotes.value = (_profileNotes.value + fresh).sortedByDescending { it.createdAt }
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

    /** Bumped when a stream is replaced so an older page's check can't end paging. */
    private var pageToken = 0

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
            val token = pageToken
            viewModelScope.launch {
                delay(5000)
                if (token != pageToken) return@launch
                if (_taggedNotes.value.size == before) _hasMoreTagged.value = false
                _isLoadingOlder.value = false
            }
        } else {
            if (!_hasMoreNotes.value) return
            val oldest = _profileNotes.value.lastOrNull() ?: return
            _isLoadingOlder.value = true
            val before = _profileNotes.value.size
            s.loadOlder(oldest.createdAt.time / 1000)
            val token = pageToken
            viewModelScope.launch {
                delay(5000)
                if (token != pageToken) return@launch
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
        }
    }

    fun toggleBlock() {
        val pk = _pubkey.value
        if (pk.isEmpty()) return
        if (_isBlocked.value) feedService.unblockUser(pk) else feedService.blockUser(pk)
        _isBlocked.value = !_isBlocked.value
    }

    /**
     * Who a Media grid tile's Report Media / Block User act on: the note's
     * author, unless that is you (iOS `MediaGridItem` hides them for your own).
     */
    fun mediaModerationTarget(author: String): String? =
        com.nostrvault.ui.screens.mediaModerationTarget(author, nostrService.ownerHexPubkey, nostrService.activeHexPubkey)

    // ── Media grid long-press (iOS MediaGridItem's menu) ──

    private val _mediaBusyUrl = MutableStateFlow<String?>(null)
    /** The tile being saved or mirrored from its menu right now, or null. */
    val mediaBusyUrl: StateFlow<String?> = _mediaBusyUrl.asStateFlow()

    /** Each Blossom server's answer per blob, so Mirror to Blossom shows once known. */
    val mirrorPresence = blossomService.mirrorPresence

    /** The menu a tile's long-press opens, given what is known about [url] now. */
    fun mediaMenu(url: String, author: String, presence: Map<String, Map<String, com.nostrvault.service.BlobPresence>>): List<ProfileMediaAction> {
        val sha = blossomHashOf(url)
        val inVault = sha != null && mediaCacheService.isInLocalBlossom(sha)
        return profileMediaMenu(
            url = url,
            inVault = inVault,
            needsMirror = inVault && sha != null && blossomService.backupSummary(sha, presence)?.needsMirror == true,
            is404 = mediaCacheService.isKnown404(url),
            moderationTarget = mediaModerationTarget(author),
        )
    }

    /** Asks the Blossom servers about [url]'s blob once, so the menu can offer a mirror. */
    suspend fun checkMediaBackup(url: String) {
        val sha = blossomHashOf(url) ?: return
        if (mediaCacheService.isInLocalBlossom(sha)) blossomService.checkMirrorPresence(sha)
    }

    fun toggleMedia404(url: String) {
        if (mediaCacheService.isKnown404(url)) mediaCacheService.unmarkNotFound(url) else mediaCacheService.markNotFound(url)
    }

    fun saveMediaToPhotos(url: String) {
        viewModelScope.launch {
            val result = mediaSaveService.saveToGallery(url, com.nostrvault.service.MediaSaveService.mimeTypeForExtension(url))
            _toast.value = if (result.isSuccess) "Saved to gallery" else "Couldn't save to gallery"
        }
    }

    /**
     * Stores the file in the vault on this phone, then uploads it to any
     * Blossom server that lacks it. Port of iOS `MediaBackupActions.saveToVault`.
     */
    fun saveMediaToVault(url: String) {
        if (_mediaBusyUrl.value != null) return
        viewModelScope.launch {
            _mediaBusyUrl.value = url
            try {
                val saved = blossomService.mirrorUrlToLocal(url)
                if (saved == null) {
                    _toast.value = "Could not save to your vault"
                    return@launch
                }
                val backedUp = configStore.config.value.activeBlossomMirrors.isNotEmpty() &&
                    pushMissing(saved).let { it == null || it is com.nostrvault.service.BlossomService.MirrorPushResult.AllAccepted }
                _toast.value = if (backedUp) "Saved to your vault and your Blossom" else "Saved to your vault on this phone"
            } finally {
                _mediaBusyUrl.value = null
            }
        }
    }

    /** Uploads a file already on this phone to the servers that lack it (iOS `mirrorMissing`). */
    fun mirrorMediaToBlossom(url: String) {
        val sha = blossomHashOf(url) ?: return
        if (_mediaBusyUrl.value != null) return
        viewModelScope.launch {
            _mediaBusyUrl.value = url
            try {
                _toast.value = when (val result = pushMissing(sha)) {
                    null -> "Already on all your Blossom servers"
                    else -> result.message
                }
            } finally {
                _mediaBusyUrl.value = null
            }
        }
    }

    /** Null when every server already had it; otherwise the push result. Re-checks after. */
    private suspend fun pushMissing(sha256: String): com.nostrvault.service.BlossomService.MirrorPushResult? {
        blossomService.checkMirrorPresence(sha256, force = true)
        val summary = blossomService.backupSummary(sha256)
        if (summary != null && !summary.needsMirror) return null
        val result = blossomService.pushLocalToMirrors(sha256, only = summary?.missing)
        blossomService.checkMirrorPresence(sha256, force = true)
        return result
    }

    fun reportAuthor(pubkey: String, reason: String, description: String) {
        nostrService.reportUser(pubkey, reason, description.ifBlank { null })
    }

    /** Blocks [pubkey]; the header's Blocked state follows when it is this profile. */
    fun blockAuthor(pubkey: String) {
        feedService.blockUser(pubkey)
        if (pubkey == _pubkey.value) _isBlocked.value = true
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

    /** Zap this profile: [amount] sats, the default unless chosen in the custom sheet. */
    fun zap(amount: Int = defaultZapSats) {
        val pk = _pubkey.value
        if (pk.isEmpty()) return
        viewModelScope.launch {
            val result = zapSendService.zapNote(pk, pk, amount)
            _toast.value = result.fold(
                onSuccess = { "Zapped $amount sats" },
                onFailure = { "Zap failed: ${it.message ?: "unknown error"}" },
            )
        }
    }

    fun clearToast() { _toast.value = null }

    /** Zap a post (default amount) — feedback via [toast]. */
    fun zapNote(noteId: String, notePubkey: String) {
        val amount = defaultZapSats
        viewModelScope.launch {
            val result = zapSendService.zapNote(noteId, notePubkey, amount)
            _toast.value = result.fold(
                onSuccess = {
                    ZapFlight.launch(noteId)
                    "Zapped $amount sats"
                },
                onFailure = { "Zap failed: ${it.message ?: "unknown error"}" },
            )
        }
    }

    /** Your own notes have no trust path, so they get no Web of Trust button. */
    fun isOwnNote(pubkey: String): Boolean = pubkey == nostrService.activeHexPubkey

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

    fun fetchMissingQuotedNotes(identifiers: List<String>) =
        feedService.fetchMissingQuotedNotes(identifiers)

    fun fetchMissingQuotedProfiles(identifiers: List<String>) =
        feedService.fetchMissingQuotedProfiles(identifiers)

    override fun onCleared() {
        super.onCleared()
        stream?.close()
        stream = null
    }
}

/** A repost on this profile: a kind 6, resolved to its original or still bare. */
internal val FeedNote.isProfileRepost: Boolean get() = kind == 6 || repostedBy != null

/**
 * This person's own pictures and video, from posts and replies alike. A
 * repost's media is someone else's, so it stays out.
 */
internal val FeedNote.isProfileMedia: Boolean get() = mediaURLs.isNotEmpty() && !isProfileRepost
