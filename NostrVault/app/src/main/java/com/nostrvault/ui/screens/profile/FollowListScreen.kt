package com.nostrvault.ui.screens.profile

import androidx.compose.animation.core.RepeatMode
import androidx.compose.animation.core.animateFloat
import androidx.compose.animation.core.infiniteRepeatable
import androidx.compose.animation.core.rememberInfiniteTransition
import androidx.compose.animation.core.tween
import androidx.compose.foundation.ExperimentalFoundationApi
import androidx.compose.foundation.background
import androidx.compose.foundation.border
import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.heightIn
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.statusBarsPadding
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.layout.widthIn
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.items
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.foundation.text.KeyboardOptions
import androidx.compose.material3.CircularProgressIndicator
import androidx.compose.material3.DropdownMenu
import androidx.compose.material3.DropdownMenuItem
import androidx.compose.material3.HorizontalDivider
import androidx.compose.material3.Icon
import androidx.compose.material3.IconButton
import androidx.compose.material3.OutlinedTextField
import androidx.compose.material3.OutlinedTextFieldDefaults
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.collectAsState
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.saveable.rememberSaveable
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.alpha
import androidx.compose.ui.draw.clip
import androidx.compose.ui.draw.rotate
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.semantics.Role
import androidx.compose.ui.semantics.clearAndSetSemantics
import androidx.compose.ui.semantics.contentDescription
import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.text.font.FontFamily
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.input.ImeAction
import androidx.compose.ui.text.style.TextAlign
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import androidx.hilt.navigation.compose.hiltViewModel
import androidx.lifecycle.SavedStateHandle
import androidx.lifecycle.ViewModel
import androidx.lifecycle.viewModelScope
import com.nostrvault.data.local.ConfigStore
import com.nostrvault.data.model.FeedProfile
import com.nostrvault.data.model.FollowerSnapshot
import com.nostrvault.relay.HavenBridge
import com.nostrvault.service.FeedService
import com.nostrvault.service.NostrService
import com.nostrvault.ui.components.AvatarImage
import com.nostrvault.ui.theme.LocalNostrVaultColors
import com.nostrvault.ui.theme.NostrVaultIcons
import com.nostrvault.ui.theme.PlaceholderText
import com.nostrvault.ui.theme.PrimaryText
import com.nostrvault.ui.theme.SecondaryText
import com.nostrvault.ui.theme.SeparatorColor
import com.nostrvault.ui.theme.Surface1
import com.nostrvault.ui.theme.Surface2
import com.nostrvault.ui.theme.WindowBackground
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
    configStore: ConfigStore,
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

// ── Screen ───────────────────────────────────────────────────────────

/**
 * The page a profile's FOLLOWING / FOLLOWERS counts open: a Following |
 * Followers switch and search pinned on a solid header, then three groups
 * with sticky headers. Tapping a row opens that profile on the same back
 * stack. Port of iOS `FollowListView`.
 */
@OptIn(ExperimentalFoundationApi::class)
@Composable
fun FollowListScreen(
    onProfileClick: (String) -> Unit,
    onBack: () -> Unit,
    viewModel: FollowListViewModel = hiltViewModel(),
) {
    val following by viewModel.following.collectAsState()
    val followers by viewModel.followers.collectAsState()
    val exhausted by viewModel.followersExhausted.collectAsState()
    val pagesDone by viewModel.pagesDone.collectAsState()
    val isOwnLedger by viewModel.isOwnLedger.collectAsState()
    val followersTotal by viewModel.followersTotal.collectAsState()
    val followsViewer by viewModel.followsViewer.collectAsState()
    val hidden by viewModel.hidden.collectAsState()
    val webOfTrust by viewModel.webOfTrust.collectAsState()
    val trustRank by viewModel.trustRank.collectAsState()
    val followedList by viewModel.followed.collectAsState()
    val queued by viewModel.queued.collectAsState()
    val profiles by viewModel.profiles.collectAsState()
    val followed = remember(followedList) { followedList.toHashSet() }

    var tab by rememberSaveable { mutableStateOf(viewModel.startTab) }
    var query by rememberSaveable { mutableStateOf("") }
    var showOutside by rememberSaveable { mutableStateOf(false) }
    var sorts by remember { mutableStateOf(FollowListSortMemory.sorts.toMap()) }
    val sort = sorts[tab] ?: FollowListSort.TRUSTED
    val haveMore = !isOwnLedger && !exhausted

    val people = remember(tab, following, followers, profiles) {
        when (tab) {
            FollowListTab.FOLLOWING -> following.mapIndexed { i, key -> person(key, i.toLong(), profiles[key]) }
            FollowListTab.FOLLOWERS -> followers.map { (key, at) -> person(key, at, profiles[key]) }
        }
    }
    val sections = remember(people, followed, webOfTrust, trustRank, hidden, sort, query) {
        FollowListLogic.sections(people, followed, webOfTrust, trustRank, hidden, sort, query)
    }
    val subjectName = profiles[viewModel.subject]?.bestName ?: shortNpub(viewModel.subject)
    val followersLabel = followersTotal?.takeIf { it > followers.size }
        ?.let { FollowListLogic.countText(it, more = false) }
        ?: FollowListLogic.countText(followers.size, more = haveMore)

    Column(
        modifier = Modifier
            .fillMaxSize()
            .background(WindowBackground),
    ) {
        // Solid, never scrolls: rows and the group headers pass under it.
        Column(
            modifier = Modifier
                .fillMaxWidth()
                .background(WindowBackground)
                .statusBarsPadding()
                .padding(horizontal = 12.dp),
        ) {
            Row(verticalAlignment = Alignment.CenterVertically, modifier = Modifier.fillMaxWidth().height(52.dp)) {
                IconButton(onClick = onBack, modifier = Modifier.size(48.dp)) {
                    Icon(NostrVaultIcons.Back, "Back", tint = PrimaryText, modifier = Modifier.size(24.dp))
                }
                Text(
                    subjectName,
                    color = PrimaryText,
                    fontSize = 17.sp,
                    fontWeight = FontWeight.SemiBold,
                    maxLines = 1,
                    overflow = TextOverflow.Ellipsis,
                    textAlign = TextAlign.Center,
                    modifier = Modifier.weight(1f),
                )
                SortMenu(sort) { picked ->
                    FollowListSortMemory.sorts[tab] = picked
                    sorts = FollowListSortMemory.sorts.toMap()
                }
            }
            SearchField(query, placeholder = "Search ${tab.title.lowercase()}") { query = it }
            Spacer(Modifier.height(10.dp))
            TabSwitch(
                tab = tab,
                followingLabel = "Following ${FollowListLogic.countText(following.size, more = false)}",
                followersLabel = "Followers $followersLabel",
                onSelect = { tab = it },
            )
            Spacer(Modifier.height(10.dp))
        }
        HorizontalDivider(color = SeparatorColor, thickness = 0.5.dp)

        LazyColumn(modifier = Modifier.fillMaxSize()) {
            if (sections.isEmpty()) {
                item(key = "empty") {
                    Text(
                        when {
                            query.isNotBlank() -> "No one matches “${query.trim()}”"
                            tab == FollowListTab.FOLLOWING -> "Not following anyone yet"
                            else -> "No followers found yet"
                        },
                        color = SecondaryText,
                        fontSize = 14.sp,
                        textAlign = TextAlign.Center,
                        modifier = Modifier.fillMaxWidth().padding(vertical = 48.dp),
                    )
                }
            }
            for (section in sections) {
                val collapsible = section.group == FollowListGroup.OUTSIDE && query.isBlank()
                stickyHeader(key = "h-${section.group}") {
                    SectionHeader(section, collapsible, open = showOutside) { showOutside = !showOutside }
                }
                if (!collapsible || showOutside) {
                    items(section.people, key = { "${section.group}-${it.pubkey}" }) { p ->
                        val isViewer = p.pubkey == viewModel.viewer
                        LaunchedEffect(p.pubkey) { viewModel.needProfile(p.pubkey) }
                        FollowListRow(
                            pubkey = p.pubkey,
                            name = p.name,
                            profile = profiles[p.pubkey],
                            followsYou = !isViewer &&
                                !(tab == FollowListTab.FOLLOWERS && isOwnLedger) &&
                                p.pubkey in followsViewer,
                            followState = if (isViewer) null else viewModel.state(p.pubkey, followed, queued),
                            onOpen = {
                                // This page already shows that profile, and you are
                                // not someone to open from a list of your own.
                                if (!isViewer && p.pubkey != viewModel.subject) onProfileClick(p.pubkey)
                            },
                            onToggleFollow = { viewModel.toggle(p.pubkey) },
                        )
                        HorizontalDivider(color = SeparatorColor, thickness = 0.5.dp, modifier = Modifier.padding(start = 72.dp))
                    }
                }
            }
            if (tab == FollowListTab.FOLLOWERS && haveMore) {
                item(key = "more-$pagesDone") {
                    // A new key per finished page, so a loader still on screen
                    // after a page asks for the next one.
                    LaunchedEffect(pagesDone) { viewModel.loadMoreFollowers() }
                    Box(Modifier.fillMaxWidth().padding(vertical = 20.dp), contentAlignment = Alignment.Center) {
                        CircularProgressIndicator(color = SecondaryText, strokeWidth = 2.dp, modifier = Modifier.size(22.dp))
                    }
                }
            }
        }
    }
}

private fun person(key: String, recency: Long, profile: FeedProfile?) = FollowListPerson(
    pubkey = key,
    name = profile?.bestName ?: shortNpub(key),
    nip05 = profile?.nip05.orEmpty(),
    recency = recency,
)

internal fun shortNpub(hex: String): String {
    val npub = runCatching { HavenBridge.encodeNpub(hex) }.getOrNull() ?: hex
    return npub.take(16) + "…"
}

@Composable
private fun SortMenu(sort: FollowListSort, onPick: (FollowListSort) -> Unit) {
    var open by remember { mutableStateOf(false) }
    Box {
        IconButton(
            onClick = { open = true },
            modifier = Modifier.size(48.dp).semantics { contentDescription = "Sort, ${sort.title}" },
        ) {
            Icon(NostrVaultIcons.Sort, null, tint = PrimaryText, modifier = Modifier.size(22.dp))
        }
        DropdownMenu(expanded = open, onDismissRequest = { open = false }) {
            FollowListSort.entries.forEach { option ->
                DropdownMenuItem(
                    text = { Text(option.title) },
                    leadingIcon = {
                        if (option == sort) Icon(NostrVaultIcons.Check, null, modifier = Modifier.size(18.dp))
                        else Spacer(Modifier.size(18.dp))
                    },
                    onClick = { open = false; onPick(option) },
                )
            }
        }
    }
}

@Composable
private fun SearchField(query: String, placeholder: String, onChange: (String) -> Unit) {
    val colors = LocalNostrVaultColors.current
    OutlinedTextField(
        value = query,
        onValueChange = onChange,
        placeholder = { Text(placeholder, color = PlaceholderText) },
        leadingIcon = { Icon(NostrVaultIcons.Search, null, tint = SecondaryText) },
        trailingIcon = {
            if (query.isNotEmpty()) {
                IconButton(onClick = { onChange("") }) { Icon(NostrVaultIcons.Dismiss, "Clear", tint = SecondaryText) }
            }
        },
        singleLine = true,
        keyboardOptions = KeyboardOptions(imeAction = ImeAction.Search),
        colors = OutlinedTextFieldDefaults.colors(
            focusedBorderColor = colors.primary,
            unfocusedBorderColor = SeparatorColor,
            cursorColor = colors.primary,
        ),
        shape = RoundedCornerShape(12.dp),
        modifier = Modifier.fillMaxWidth(),
    )
}

/** Two-segment switch, iOS segmented-control style. */
@Composable
private fun TabSwitch(
    tab: FollowListTab,
    followingLabel: String,
    followersLabel: String,
    onSelect: (FollowListTab) -> Unit,
) {
    Row(
        modifier = Modifier
            .fillMaxWidth()
            .height(40.dp)
            .clip(RoundedCornerShape(10.dp))
            .background(Surface1)
            .padding(3.dp),
    ) {
        for ((option, label) in listOf(FollowListTab.FOLLOWING to followingLabel, FollowListTab.FOLLOWERS to followersLabel)) {
            val selected = option == tab
            Box(
                contentAlignment = Alignment.Center,
                modifier = Modifier
                    .weight(1f)
                    .fillMaxSize()
                    .clip(RoundedCornerShape(8.dp))
                    .background(if (selected) Surface2 else Color.Transparent)
                    .clickable(role = Role.Tab) { onSelect(option) },
            ) {
                Text(
                    label,
                    color = PrimaryText,
                    fontSize = 13.sp,
                    fontWeight = if (selected) FontWeight.SemiBold else FontWeight.Normal,
                    maxLines = 1,
                )
            }
        }
    }
}

@Composable
private fun SectionHeader(section: FollowListSection, collapsible: Boolean, open: Boolean, onToggle: () -> Unit) {
    Row(
        verticalAlignment = Alignment.CenterVertically,
        modifier = Modifier
            .fillMaxWidth()
            // Solid: rows pass under a pinned header, never show through it.
            .background(WindowBackground)
            .heightIn(min = if (collapsible) 48.dp else 32.dp)
            .then(if (collapsible) Modifier.clickable(role = Role.Button, onClick = onToggle) else Modifier)
            .padding(horizontal = 16.dp, vertical = 8.dp),
    ) {
        Text(
            section.group.title.uppercase(),
            color = SecondaryText,
            fontSize = 11.sp,
            fontWeight = FontWeight.SemiBold,
            letterSpacing = 0.6.sp,
        )
        Spacer(Modifier.width(6.dp))
        Text(
            "${section.people.size}",
            color = SecondaryText,
            fontSize = 11.sp,
            fontWeight = FontWeight.Bold,
            fontFamily = FontFamily.Monospace,
        )
        Spacer(Modifier.weight(1f))
        if (collapsible) {
            Icon(
                NostrVaultIcons.ChevronDown,
                contentDescription = if (open) "Hide this group" else "Show this group",
                tint = SecondaryText,
                modifier = Modifier.size(18.dp).rotate(if (open) 0f else -90f),
            )
        }
    }
}

@Composable
private fun FollowListRow(
    pubkey: String,
    name: String,
    profile: FeedProfile?,
    followsYou: Boolean,
    /** null hides the button (your own row). */
    followState: FollowButtonState?,
    onOpen: () -> Unit,
    onToggleFollow: () -> Unit,
) {
    // A profile that never arrives stops shimmering after a while.
    var gaveUp by remember(pubkey) { mutableStateOf(false) }
    LaunchedEffect(pubkey, profile == null) {
        if (profile == null) { delay(8_000); gaveUp = true }
    }
    Row(
        verticalAlignment = Alignment.CenterVertically,
        modifier = Modifier.fillMaxWidth().padding(start = 16.dp, end = 12.dp, top = 8.dp, bottom = 8.dp),
    ) {
        // The row's tap target. The Follow button is a sibling, not inside it,
        // so it keeps its own tap.
        Row(
            verticalAlignment = Alignment.Top,
            modifier = Modifier.weight(1f).clickable(role = Role.Button, onClick = onOpen),
        ) {
            val url = profile?.pictureURL?.takeIf { it.isNotBlank() }
            if (url != null) {
                AvatarImage(url = url, pubkey = pubkey, size = 44.dp, displayName = profile.bestName)
            } else {
                EmptyAvatar()
            }
            Spacer(Modifier.width(12.dp))
            Column(modifier = Modifier.weight(1f)) {
                Row(verticalAlignment = Alignment.CenterVertically) {
                    Text(
                        name,
                        color = PrimaryText,
                        fontSize = 15.sp,
                        fontWeight = FontWeight.SemiBold,
                        maxLines = 1,
                        overflow = TextOverflow.Ellipsis,
                        modifier = Modifier.weight(1f, fill = false),
                    )
                    if (!profile?.nip05.isNullOrBlank()) {
                        Spacer(Modifier.width(4.dp))
                        Icon(NostrVaultIcons.Verified, "Verified", tint = Color(0xFF33CC99), modifier = Modifier.size(13.dp))
                    }
                    if (followsYou) {
                        Spacer(Modifier.width(5.dp))
                        Text(
                            "Follows you",
                            color = SecondaryText,
                            fontSize = 10.sp,
                            fontWeight = FontWeight.SemiBold,
                            maxLines = 1,
                            modifier = Modifier
                                .clip(RoundedCornerShape(50))
                                .background(SecondaryText.copy(alpha = 0.16f))
                                .padding(horizontal = 6.dp, vertical = 2.dp),
                        )
                    }
                }
                Spacer(Modifier.height(3.dp))
                BioLines(
                    bio = FollowListLogic.bioLine(profile?.about),
                    loading = profile == null && !gaveUp,
                )
            }
        }
        if (followState != null) {
            Spacer(Modifier.width(8.dp))
            FollowButton(followState, name, onToggleFollow)
        }
    }
}

/** Always two lines tall, so rows keep one height as profiles land. */
@Composable
private fun BioLines(bio: String?, loading: Boolean) {
    Box {
        // Plain text: links in a bio are not tappable here, so the whole row
        // stays one tap target.
        Text(
            if (loading) " " else bio ?: " ",
            color = SecondaryText,
            fontSize = 13.sp,
            lineHeight = 17.sp,
            minLines = 2,
            maxLines = 2,
            overflow = TextOverflow.Ellipsis,
        )
        if (loading) {
            val pulse by rememberInfiniteTransition(label = "bio").animateFloat(
                initialValue = 1f,
                targetValue = 0.5f,
                animationSpec = infiniteRepeatable(tween(900), RepeatMode.Reverse),
                label = "bioPulse",
            )
            Column(
                verticalArrangement = Arrangement.SpaceEvenly,
                modifier = Modifier.matchParentSize().alpha(pulse),
            ) {
                Box(Modifier.fillMaxWidth(0.95f).height(10.dp).clip(RoundedCornerShape(4.dp)).background(Surface1))
                Box(Modifier.fillMaxWidth(0.7f).height(10.dp).clip(RoundedCornerShape(4.dp)).background(Surface1))
            }
        }
    }
}

@Composable
private fun EmptyAvatar() {
    Box(
        contentAlignment = Alignment.Center,
        modifier = Modifier.size(44.dp).clip(CircleShape).background(Surface2),
    ) {
        Icon(NostrVaultIcons.Profile, null, tint = SecondaryText.copy(alpha = 0.6f), modifier = Modifier.size(22.dp))
    }
}

/** Filled "Follow", outlined "Following". Drawn 32dp tall; the tap target is 48dp. */
@Composable
private fun FollowButton(state: FollowButtonState, name: String, onClick: () -> Unit) {
    val colors = LocalNostrVaultColors.current
    val filled = when (state) {
        FollowButtonState.Follow -> true
        FollowButtonState.Following -> false
        is FollowButtonState.Pending -> !state.follow
    }
    val pending = state is FollowButtonState.Pending
    Box(
        contentAlignment = Alignment.Center,
        modifier = Modifier
            .heightIn(min = 48.dp)
            .widthIn(min = 88.dp)
            // Same wording as iOS: the label names the person so TalkBack and
            // Voice Access can tell rows apart; the action says what a tap does.
            .clickable(role = Role.Button, onClickLabel = if (filled) null else "Unfollow", onClick = onClick)
            .semantics { contentDescription = if (filled) "Follow $name" else "Following $name" },
    ) {
        Box(
            contentAlignment = Alignment.Center,
            modifier = Modifier
                .alpha(if (pending) 0.6f else 1f)
                .height(32.dp)
                .widthIn(min = 84.dp)
                .clip(RoundedCornerShape(50))
                .background(if (filled) colors.primary else Color.Transparent)
                .then(
                    if (filled) Modifier
                    else Modifier.border(1.dp, SecondaryText.copy(alpha = 0.45f), RoundedCornerShape(50)),
                )
                .padding(horizontal = 12.dp),
        ) {
            Text(
                if (filled) "Follow" else "Following",
                color = if (filled) Color.White else PrimaryText,
                fontSize = 13.sp,
                fontWeight = FontWeight.SemiBold,
                maxLines = 1,
                modifier = Modifier.clearAndSetSemantics {},
            )
        }
    }
}
