package com.nostrvault.ui.screens.profile

import androidx.compose.foundation.layout.size
import androidx.lifecycle.SavedStateHandle
import androidx.lifecycle.ViewModel
import androidx.lifecycle.viewModelScope
import com.nostrvault.data.local.ConfigStore
import com.nostrvault.data.model.FeedProfile
import com.nostrvault.data.model.FollowerSnapshot
import com.nostrvault.relay.HavenBridge
import com.nostrvault.service.FeedService
import com.nostrvault.service.NostrService
import com.nostrvault.service.profileRelayUrls
import dagger.hilt.android.lifecycle.HiltViewModel
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.Job
import kotlinx.coroutines.delay
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.SharingStarted
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.asStateFlow
import kotlinx.coroutines.flow.map
import kotlinx.coroutines.flow.stateIn
import kotlinx.coroutines.launch
import kotlinx.coroutines.withContext
import kotlinx.serialization.json.JsonPrimitive
import kotlinx.serialization.json.contentOrNull
import kotlinx.serialization.json.longOrNull
import javax.inject.Inject

/** The sort chosen on each tab, kept for the rest of the session. */
object FollowListSortMemory {
    val sorts = mutableMapOf<FollowListTab, FollowListSort>()
}

/** A follow tapped before the follow list loaded; lands once it does. */
sealed class FollowButtonState {
    data object Follow : FollowButtonState()
    data object Following : FollowButtonState()
    data class Pending(val follow: Boolean) : FollowButtonState()
}

/**
 * Everyone on a profile's Following and Followers lists. Port of the data
 * half of iOS `ProfileView` + `FollowListView`.
 *
 * Your own followers come from the relay's follower ledger, so that list is
 * complete and spam is hidden. Anyone else's are what relays return, a page
 * of 100 at a time, oldest-first paging as the list scrolls.
 */
@HiltViewModel
class FollowListViewModel @Inject constructor(
    savedStateHandle: SavedStateHandle,
    private val nostrService: NostrService,
    private val feedService: FeedService,
    private val configStore: ConfigStore,
) : ViewModel() {

    companion object {
        private const val PAGE = 100
        private const val PAGE_TIMEOUT_MS = 6_000L
    }

    val subject: String = savedStateHandle.get<String>("pubkey").orEmpty()
    val startTab: FollowListTab = savedStateHandle.get<String>("tab")
        ?.let { runCatching { FollowListTab.valueOf(it) }.getOrNull() } ?: FollowListTab.FOLLOWING
    /** The profile page's follower count, which can be ahead of the list while pages load. */
    private val profileFollowersTotal: Int? = savedStateHandle.get<String>("total")?.toIntOrNull()?.takeIf { it > 0 }

    val viewer: String = configStore.activeAccountHexPubkey.value
    val isOwn: Boolean = subject == viewer

    /**
     * True once another account is active. Everything here was read for
     * [viewer], but the follow buttons act on the active account's list: left
     * open across a switch, your Following list showed the new account's
     * follows and each tap edited and published that account's list. The
     * screen closes instead.
     */
    val accountChanged: StateFlow<Boolean> = configStore.activeAccountHexPubkey
        .map { it != viewer }
        .stateIn(viewModelScope, SharingStarted.Eagerly, false)

    val profiles: StateFlow<Map<String, FeedProfile>> = nostrService.profiles
    val followed: StateFlow<List<String>> = feedService.followedPubkeys

    private val _following = MutableStateFlow<List<String>>(emptyList())
    /** Contact-list order. */
    val following: StateFlow<List<String>> = if (isOwn) {
        feedService.followedPubkeys
            .map { list -> list.filter { it != subject } }
            .stateIn(viewModelScope, SharingStarted.Eagerly, feedService.followedPubkeys.value.filter { it != subject })
    } else {
        _following.asStateFlow()
    }

    /** Follower → when their list naming the subject was published. */
    private val _followers = MutableStateFlow<Map<String, Long>>(emptyMap())
    val followers: StateFlow<Map<String, Long>> = _followers.asStateFlow()

    private val _followersExhausted = MutableStateFlow(false)
    val followersExhausted: StateFlow<Boolean> = _followersExhausted.asStateFlow()

    /** Follower pages finished; keys the loader so it asks again after a page that added nobody. */
    private val _pagesDone = MutableStateFlow(0)
    val pagesDone: StateFlow<Int> = _pagesDone.asStateFlow()

    /** True once your own complete follower ledger is the Followers list. */
    private val _isOwnLedger = MutableStateFlow(false)
    val isOwnLedger: StateFlow<Boolean> = _isOwnLedger.asStateFlow()

    private val _followersTotal = MutableStateFlow(profileFollowersTotal)
    val followersTotal: StateFlow<Int?> = _followersTotal.asStateFlow()

    /** People who follow the viewer, for the "Follows you" tag. */
    private val _followsViewer = MutableStateFlow<Set<String>>(emptySet())
    val followsViewer: StateFlow<Set<String>> = _followsViewer.asStateFlow()

    /** Spam from the viewer's ledger, hidden from both lists. */
    private val _hidden = MutableStateFlow<Set<String>>(emptySet())
    val hidden: StateFlow<Set<String>> = _hidden.asStateFlow()

    /**
     * Everyone the viewer blocks, as hex pubkeys. Dropped from both lists
     * and from the counts beside the switch, live as you block: the relay
     * never hears about blocks on Android, and anyone who followed before
     * being blocked is already in the ledger either way.
     */
    val blocked: StateFlow<Set<String>> = configStore.config
        .map { config -> config.blockedForActiveAccount().mapNotNull { nostrService.npubToHex(it) }.toSet() }
        .stateIn(viewModelScope, SharingStarted.Eagerly, emptySet())

    private val _webOfTrust = MutableStateFlow<Set<String>>(emptySet())
    val webOfTrust: StateFlow<Set<String>> = _webOfTrust.asStateFlow()
    private val _trustRank = MutableStateFlow<Map<String, Int>>(emptyMap())
    val trustRank: StateFlow<Map<String, Int>> = _trustRank.asStateFlow()

    /** Taps queued until the follow list loads: pubkey → follow? */
    private val _queued = MutableStateFlow<Map<String, Boolean>>(emptyMap())
    val queued: StateFlow<Map<String, Boolean>> = _queued.asStateFlow()

    private val relays = nostrService.profileRelayUrls(subject)
    private var pageJob: Job? = null
    private var quietPages = 0
    private val profileBatch = mutableSetOf<String>()
    private var profileFlush: Job? = null

    init {
        loadTrust()
        if (!isOwn) viewModelScope.launch { loadFollowing() }
        pageJob = viewModelScope.launch {
            // Your own followers come from the ledger; relays only when it
            // can't be read.
            if (!loadLedger() || !isOwn) loadFollowerPage(until = null)
        }
        // A queued tap has landed once the list agrees with it.
        viewModelScope.launch {
            feedService.followedPubkeys.collect { list ->
                val set = list.toHashSet()
                _queued.value = _queued.value.filter { (key, follow) -> (key in set) != follow }
            }
        }
    }

    fun state(pubkey: String, followed: Set<String>, queued: Map<String, Boolean>): FollowButtonState =
        queued[pubkey]?.let { FollowButtonState.Pending(it) }
            ?: if (pubkey in followed) FollowButtonState.Following else FollowButtonState.Follow

    /**
     * Changes the follow at once. If the new list can't be published the feed
     * puts the old one back and the button follows; the pill offers Undo.
     */
    fun toggle(pubkey: String) = set(pubkey, follow = !feedService.isFollowing(pubkey), offerUndo = true)

    /**
     * Undo names its direction: if the change was already rolled back, it
     * does nothing rather than flip the follow again.
     */
    private fun set(pubkey: String, follow: Boolean, offerUndo: Boolean) {
        // Never for an account this screen was not opened as (see accountChanged).
        if (configStore.activeAccountHexPubkey.value != viewer) return
        if (feedService.isFollowing(pubkey) == follow) return
        val undo: (() -> Unit)? = if (offerUndo) { { set(pubkey, follow = !follow, offerUndo = false) } } else null
        val result = if (follow) feedService.followUser(pubkey, undo) else feedService.unfollowUser(pubkey, undo)
        result.exceptionOrNull()?.let { err ->
            if (err is com.nostrvault.service.FollowActionError.ContactsNotLoaded ||
                err is com.nostrvault.service.ContactManager.FollowActionError.ListUnavailable
            ) {
                _queued.value = _queued.value + (pubkey to follow)
            }
        }
    }

    /** Profiles load in small batches as rows scroll into view. */
    fun needProfile(pubkey: String) {
        if (profiles.value[pubkey] != null) return
        profileBatch.add(pubkey)
        profileFlush?.cancel()
        profileFlush = viewModelScope.launch {
            delay(250)
            if (profileBatch.isEmpty()) return@launch
            val batch = profileBatch.toList()
            profileBatch.clear()
            nostrService.fetchMissingProfiles(batch)
        }
    }

    /** Asks every relay for the next 100 lists naming the subject, older than the oldest seen. */
    fun loadMoreFollowers() {
        if (_isOwnLedger.value || _followersExhausted.value || pageJob?.isActive == true) return
        // Nothing yet: the first page again, not the end of the list.
        val until = _followers.value.values.minOrNull()?.let { it - 1 }
        pageJob = viewModelScope.launch { loadFollowerPage(until) }
    }

    private suspend fun loadFollowerPage(until: Long?) {
        val before = _followers.value.size
        val untilPart = until?.let { ""","until":$it""" } ?: ""
        val filter = """{"kinds":[3],"#p":["$subject"]$untilPart,"limit":$PAGE}"""
        val events = nostrService.queryRawEvents(listOf(filter), relays, PAGE_TIMEOUT_MS) { partial ->
            merge(partial)
        }
        merge(events)
        if (_followers.value.size > before) {
            quietPages = 0
        } else {
            // Two empty rounds in a row, not one: a single quiet round is more
            // often a slow relay than the end of the list.
            quietPages += 1
            if (quietPages >= 2) _followersExhausted.value = true
        }
        _pagesDone.value += 1
    }

    @Synchronized
    private fun merge(events: List<kotlinx.serialization.json.JsonObject>) {
        if (events.isEmpty()) return
        val next = _followers.value.toMutableMap()
        for (ev in events) {
            val pk = (ev["pubkey"] as? JsonPrimitive)?.contentOrNull ?: continue
            if (pk == subject) continue
            val at = (ev["created_at"] as? JsonPrimitive)?.longOrNull ?: 0L
            next[pk] = maxOf(next[pk] ?: 0L, at)
        }
        _followers.value = next
    }

    private suspend fun loadFollowing() {
        val event = nostrService.fetchNewestReplaceable(3, subject, relays) ?: return
        _following.value = event.tags
            .filter { it.size >= 2 && it[0] == "p" && it[1] != subject }
            .map { it[1] }
            .distinct()
    }

    /** False when the ledger can't be read (relay stopped). */
    private suspend fun loadLedger(): Boolean {
        val snapshot = withContext(Dispatchers.IO) {
            runCatching { FollowerSnapshot.parse(HavenBridge.getFollowers(viewer)) }.getOrNull()
        } ?: return false
        val current = snapshot.current
        _followsViewer.value = current.map { it.pubkey }.toHashSet()
        _hidden.value = snapshot.followers.orEmpty().filter { it.isSpam }.map { it.pubkey }.toHashSet()
        if (isOwn) {
            _followers.value = current.associate { it.pubkey to if (it.existing) it.listAt else it.followedAt }
            _isOwnLedger.value = true
            _followersExhausted.value = true
        }
        return true
    }

    private fun loadTrust() {
        // The relay's graph loads lazily; this reads it if nothing has yet.
        val extended = feedService.extendedNetworkPubkeys.value
        _webOfTrust.value = feedService.relayTabTrustedPubkeys() + extended
        val rank = HashMap<String, Int>()
        extended.forEachIndexed { index, key -> rank.putIfAbsent(key, index) }
        _trustRank.value = rank
    }
}
