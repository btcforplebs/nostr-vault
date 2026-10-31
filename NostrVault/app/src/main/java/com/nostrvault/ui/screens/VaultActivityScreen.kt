package com.nostrvault.ui.screens

import com.nostrvault.util.RelativeTime
import com.nostrvault.ui.components.rememberFilterNoteState
import com.nostrvault.ui.components.countNote
import com.nostrvault.ui.components.VaultRightPill
import com.nostrvault.data.model.VaultActivityFilter
import androidx.compose.runtime.setValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.saveable.rememberSaveable
import androidx.compose.foundation.background
import androidx.compose.foundation.border
import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.PaddingValues
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.IntrinsicSize
import androidx.compose.foundation.layout.fillMaxHeight
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.offset
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.statusBarsPadding
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.items
import androidx.compose.foundation.lazy.rememberLazyListState
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material3.CircularProgressIndicator
import androidx.compose.material3.ExperimentalMaterial3Api
import androidx.compose.material3.Icon
import androidx.compose.material3.Surface
import androidx.compose.material3.Text
import androidx.compose.material3.pulltorefresh.PullToRefreshBox
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.collectAsState
import androidx.compose.runtime.derivedStateOf
import androidx.compose.runtime.getValue
import androidx.compose.runtime.remember
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.vector.ImageVector
import androidx.compose.ui.semantics.contentDescription
import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.semantics.stateDescription
import androidx.compose.ui.text.SpanStyle
import androidx.compose.ui.text.buildAnnotatedString
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.text.withStyle
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import androidx.lifecycle.ViewModel
import androidx.lifecycle.viewModelScope
import com.nostrvault.data.local.ConfigStore
import com.nostrvault.data.local.FollowersSeenStore
import com.nostrvault.data.model.FeedProfile
import com.nostrvault.data.model.FollowerSnapshot
import com.nostrvault.data.model.VaultActivity
import com.nostrvault.data.model.AccountUnread
import com.nostrvault.data.model.VaultAccountChip
import com.nostrvault.data.model.VaultAccountChips
import com.nostrvault.data.model.VaultAccountLine
import com.nostrvault.data.model.VaultContentFilter
import com.nostrvault.data.model.VaultMode
import com.nostrvault.data.model.VaultNoteScope
import com.nostrvault.relay.HavenBridge
import com.nostrvault.relay.RelayForegroundService
import com.nostrvault.service.FeedService
import com.nostrvault.service.NostrService
import com.nostrvault.service.ZapValidationService
import com.nostrvault.tutorials.TutorialContent
import com.nostrvault.tutorials.tutorialAnchor
import com.nostrvault.ui.components.AvatarImage
import com.nostrvault.ui.components.GlassScaffold
import com.nostrvault.ui.components.ScrollCondenseEffect
import com.nostrvault.ui.components.chromeFab
import com.nostrvault.ui.components.appendTextWithEmoji
import com.nostrvault.ui.components.customEmojiInlineContent
import com.nostrvault.ui.components.reactionEmojiSummary
import com.nostrvault.ui.components.FoldBlocked
import com.nostrvault.ui.navigation.FloatingButtonRow
import com.nostrvault.ui.navigation.FloatingButtonRow.floatingRowButton
import com.nostrvault.ui.navigation.Screen
import com.nostrvault.ui.navigation.TabReselect
import com.nostrvault.ui.theme.InfoBlue
import com.nostrvault.ui.theme.LikeRed
import com.nostrvault.ui.theme.LocalNostrVaultColors
import com.nostrvault.ui.theme.NostrVaultIcons
import com.nostrvault.ui.theme.PrimaryText
import com.nostrvault.ui.theme.RepostGreen
import com.nostrvault.ui.theme.SecondaryGroupedBg
import com.nostrvault.ui.theme.SecondaryText
import com.nostrvault.ui.theme.WarningYellow
import com.nostrvault.ui.theme.ZapOrange
import dagger.hilt.android.lifecycle.HiltViewModel
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.Job
import kotlinx.coroutines.async
import kotlinx.coroutines.awaitAll
import kotlinx.coroutines.flow.SharingStarted
import kotlinx.coroutines.flow.stateIn
import kotlinx.coroutines.delay
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.asStateFlow
import kotlinx.coroutines.flow.collectLatest
import kotlinx.coroutines.flow.combine
import kotlinx.coroutines.flow.distinctUntilChanged
import kotlinx.coroutines.flow.drop
import kotlinx.coroutines.flow.map
import kotlinx.coroutines.launch
import kotlinx.coroutines.sync.Mutex
import kotlinx.coroutines.sync.withLock
import kotlinx.coroutines.withContext
import kotlinx.serialization.json.JsonArray
import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.JsonPrimitive
import kotlinx.serialization.json.contentOrNull
import kotlinx.serialization.json.intOrNull
import kotlinx.serialization.json.longOrNull
import java.text.NumberFormat
import javax.inject.Inject
import com.nostrvault.ui.screens.dashboard.IconFilterButton
import com.nostrvault.ui.components.RevealNewestEffect

/**
 * The Vault tab's first list, "Vault": replies, mentions, likes, zaps,
 * reposts and follows from everyone, newest first, the way a notifications
 * page reads. Port of iOS VaultActivityList.swift (#506).
 *
 * It reads the same relays and filters the Notes, Likes and Zaps lists load
 * from (the local outbox and inbox, and the Mac relay when one is set): your
 * own posts, so a like can quote what it liked, and everything tagging you.
 * Follows come from the relay's follower ledger the Followers list shows.
 */
@HiltViewModel
class VaultActivityViewModel @Inject constructor(
    private val nostrService: NostrService,
    private val configStore: ConfigStore,
    private val feedService: FeedService,
    private val seenStore: FollowersSeenStore,
    private val accountUnread: com.nostrvault.data.local.AccountUnreadStore,
    logStore: com.nostrvault.relay.LogStore,
) : ViewModel() {

    /** The relay's own boot step while it starts ("Booting Haven..."), as iOS shows it. */
    val relayBootStatus: StateFlow<String> = logStore.bootStatusMessage


    private companion object {
        const val PAGE = 500
        const val OLDER_PAGE = 200
        const val QUERY_TIMEOUT_MS = 8_000L
        const val SHOW_STEP = 50
        /** The first page is twice a step, as on iOS; a filter change starts again at one step. */
        const val FIRST_SHOW = 100
        /** Kinds of others' events that reach the list. */
        val TAGGED_KINDS: Set<Int> = VaultMode.RELAY_TAB_NOTE_KINDS + setOf(7, 16, 9735)
    }

    private val events = HashMap<String, VaultActivity.Event>()
    private val eventsMutex = Mutex()
    private var follows: List<VaultActivity.Follow> = emptyList()
    /** Bumped on account switch, so a query still running for the previous account is dropped. */
    @Volatile private var generation = 0
    @Volatile private var noOlder = false
    private var rebuildJob: Job? = null

    private val _lines = MutableStateFlow<List<VaultActivity>>(emptyList())
    /** Every line, newest first; the list shows the first [shown]. */
    val lines: StateFlow<List<VaultActivity>> = _lines.asStateFlow()

    private val _shown = MutableStateFlow(FIRST_SHOW)
    val shown: StateFlow<Int> = _shown.asStateFlow()

    /** A new filter shows its first step again (iOS resets to 50). Returns how many now show. */
    fun filterChanged(): Int {
        _shown.value = SHOW_STEP
        return SHOW_STEP
    }

    private val _hasLoadedOnce = MutableStateFlow(false)
    val hasLoadedOnce: StateFlow<Boolean> = _hasLoadedOnce.asStateFlow()

    private val _isRefreshing = MutableStateFlow(false)
    val isRefreshing: StateFlow<Boolean> = _isRefreshing.asStateFlow()

    private val _isLoadingOlder = MutableStateFlow(false)

    /** Lines newer than this (unix seconds) arrived since your last visit. */
    private val _unreadSince = MutableStateFlow(Long.MAX_VALUE)
    val unreadSince: StateFlow<Long> = _unreadSince.asStateFlow()

    val profiles: StateFlow<Map<String, FeedProfile>> = nostrService.profiles

    // Every account's notifications (VaultAccountChips): with more than one
    // account on the device, chips over the list widen it to the others.

    /** Every account on the device, by hex, in switcher order. */
    val accountHexes: StateFlow<List<String>> = configStore.config
        .map { c -> c.allAccountNpubs().mapNotNull { nostrService.npubToHex(it)?.lowercase() } }
        .distinctUntilChanged()
        .stateIn(viewModelScope, SharingStarted.Eagerly, emptyList())

    private val _activeHex = MutableStateFlow(nostrService.activeHexPubkey.lowercase())
    val activeHex: StateFlow<String> = _activeHex.asStateFlow()

    private val _accountChip = MutableStateFlow<VaultAccountChip?>(null)
    /** The picked chip; null is the active account's own list, as with one account. */
    val accountChip: StateFlow<VaultAccountChip?> = _accountChip.asStateFlow()

    private val _otherLines = MutableStateFlow<Map<String, List<VaultActivity>>>(emptyMap())
    /** The other accounts' lines, by account hex, before filtering. */
    val otherLines: StateFlow<Map<String, List<VaultActivity>>> = _otherLines.asStateFlow()

    private val _otherUnreadSince = MutableStateFlow<Map<String, Long>>(emptyMap())
    /** Per other account: its lines newer than this are new since its last visit. */
    val otherUnreadSince: StateFlow<Map<String, Long>> = _otherUnreadSince.asStateFlow()

    private val _otherLoading = MutableStateFlow(false)
    val otherLoading: StateFlow<Boolean> = _otherLoading.asStateFlow()

    /** The switcher's per-account counts, for the chips. */
    val accountUnreadState: StateFlow<AccountUnread> = accountUnread.state

    private var otherJob: Job? = null

    init {
        // As the Vault's lists: load once the local relay takes connections.
        viewModelScope.launch {
            RelayForegroundService.readyForConnections.collect { ready -> if (ready) refresh() }
        }
        // The relay's importer writes inbound events straight to its DBs; the
        // log poller's tick says when, so they show up live.
        viewModelScope.launch {
            RelayForegroundService.inboxActivityTick.drop(1).collectLatest {
                delay(1_500)
                refresh()
                if (_accountChip.value != null) loadOtherAccounts()
            }
        }
        viewModelScope.launch {
            configStore.accountSwitches.collect {
                generation++
                eventsMutex.withLock { events.clear() }
                noOlder = false
                _lines.value = emptyList()
                _shown.value = FIRST_SHOW
                _hasLoadedOnce.value = false
                _unreadSince.value = Long.MAX_VALUE
                follows = emptyList()
                _activeHex.value = nostrService.activeHexPubkey.lowercase()
                resetAccountChip()
                refresh()
            }
        }
        // Who counts as blocked or outside your network changes the lines.
        viewModelScope.launch {
            combine(
                feedService.wotPubkeys,
                feedService.followedPubkeys,
                configStore.config.map { it.blockedForActiveAccount() }.distinctUntilChanged(),
            ) { _, _, _ -> }.drop(1).collect { scheduleRebuild() }
        }
    }

    /** The relays the Vault's lists read: the local outbox and inbox, and the Mac relay's. */
    private fun relays(): List<String> {
        val config = configStore.config.value
        val mac = config.macRelayWssURL
        return listOfNotNull(
            config.nostrURL,
            config.localInboxURL,
            mac.takeIf { it.isNotEmpty() },
            mac.takeIf { it.isNotEmpty() }?.let { "$it/inbox" },
        )
    }

    /** New events since the newest held (pull to refresh, a tick, a visit). */
    fun refresh() {
        viewModelScope.launch {
            val owner = nostrService.activeHexPubkey
            if (owner.isEmpty()) return@launch
            val since = eventsMutex.withLock { events.values.maxOfOrNull { it.createdAt } }
                ?.let { ",\"since\":${it - 60}" } ?: ""
            _isRefreshing.value = true
            try {
                fetch(
                    listOf(
                        """{"kinds":${kindsJson(VaultMode.RELAY_TAB_NOTE_KINDS)},"authors":["$owner"]$since,"limit":$PAGE}""",
                        """{"kinds":${kindsJson(TAGGED_KINDS)},"#p":["$owner"]$since,"limit":$PAGE}""",
                    ),
                )
            } finally {
                _isRefreshing.value = false
                _hasLoadedOnce.value = true
            }
        }
    }

    /** Shows 50 more lines, then pages older events in from the relays. */
    fun loadMore() {
        if (_shown.value < _lines.value.size) {
            _shown.value += SHOW_STEP
            return
        }
        if (noOlder || _isLoadingOlder.value) return
        viewModelScope.launch {
            val owner = nostrService.activeHexPubkey
            if (owner.isEmpty()) return@launch
            _isLoadingOlder.value = true
            try {
                val (oldestMine, oldestTagged) = eventsMutex.withLock {
                    events.values.filter { it.pubkey == owner }.minOfOrNull { it.createdAt } to
                        events.values.filter { it.pubkey != owner }.minOfOrNull { it.createdAt }
                }
                val filters = buildList {
                    oldestMine?.let { add("""{"kinds":${kindsJson(VaultMode.RELAY_TAB_NOTE_KINDS)},"authors":["$owner"],"until":${it - 1},"limit":$OLDER_PAGE}""") }
                    oldestTagged?.let { add("""{"kinds":${kindsJson(TAGGED_KINDS)},"#p":["$owner"],"until":${it - 1},"limit":$OLDER_PAGE}""") }
                }
                if (filters.isEmpty() || fetch(filters) == 0) noOlder = true
                _shown.value += SHOW_STEP
            } finally {
                _isLoadingOlder.value = false
            }
        }
    }

    /** Runs [filters] and keeps what came back. Returns how many events were new. */
    private suspend fun fetch(filters: List<String>): Int {
        val gen = generation
        val raw = runCatching { nostrService.queryRawEvents(filters, relays(), QUERY_TIMEOUT_MS) }.getOrDefault(emptyList())
        val valid = raw.mapNotNull(::parse).filter { keepsZap(it) }
        if (gen != generation) return 0
        val added = eventsMutex.withLock { valid.count { events.put(it.id, it) == null } }
        if (added > 0 || !_hasLoadedOnce.value) scheduleRebuild()
        return added
    }

    /** NIP-57: only a receipt from the publisher your LNURL names (as the Zaps list). */
    private suspend fun keepsZap(event: VaultActivity.Event): Boolean {
        if (event.kind != VaultActivity.ZAP_KIND) return true
        val recipient = event.tags.firstOrNull { it.size >= 2 && it[0] == "p" }?.get(1) ?: return false
        return ZapValidationService.isValidReceipt(event.pubkey, recipient, nostrService.profiles.value)
    }

    private fun parse(obj: JsonObject): VaultActivity.Event? {
        val id = (obj["id"] as? JsonPrimitive)?.contentOrNull ?: return null
        val pubkey = (obj["pubkey"] as? JsonPrimitive)?.contentOrNull ?: return null
        val kind = (obj["kind"] as? JsonPrimitive)?.intOrNull ?: return null
        val createdAt = (obj["created_at"] as? JsonPrimitive)?.longOrNull ?: return null
        val content = (obj["content"] as? JsonPrimitive)?.contentOrNull ?: ""
        val tags = (obj["tags"] as? JsonArray)?.mapNotNull { tag ->
            (tag as? JsonArray)?.map { (it as? JsonPrimitive)?.contentOrNull ?: "" }
        }.orEmpty()
        val images = VaultActivity.pictures(id, pubkey, kind, createdAt, content, tags)
        return VaultActivity.Event(id, pubkey, kind, createdAt, content, tags, images)
    }

    /** The follows the Followers list marks as news, from the relay's ledger. */
    fun setFollowers(snapshot: FollowerSnapshot?) {
        val news = snapshot?.current.orEmpty().filter { it.isNews }.map { VaultActivity.Follow(it.pubkey, it.followedAt) }
        if (news == follows) return
        follows = news
        scheduleRebuild()
    }

    /** The kind of a held event, so an article opens as one. */
    fun kindOf(id: String): Int? = events[id]?.kind

    private fun scheduleRebuild() {
        rebuildJob?.cancel()
        rebuildJob = viewModelScope.launch {
            delay(150)
            rebuild()
        }
    }

    private suspend fun rebuild() = withContext(Dispatchers.Default) {
        val owner = nostrService.activeHexPubkey
        val gen = generation
        val config = configStore.config.value
        val blocked = config.blockedForActiveAccount().mapNotNull { nostrService.npubToHex(it) }.toSet()
        val whitelist = config.whitelistedNpubs?.mapNotNull { nostrService.npubToHex(it) }?.toSet().orEmpty()
        val trusted = feedService.relayTabTrustedPubkeys()
        val snapshot = eventsMutex.withLock { events.values.toList() }
        val lines = VaultActivity.build(
            events = snapshot,
            owner = owner,
            noteKinds = VaultMode.RELAY_TAB_NOTE_KINDS,
            follows = follows,
            isBlocked = { it in blocked },
            isOutside = { VaultContentFilter.isOutside(it, owner, whitelist, trusted) },
        )
        if (gen != generation) return@withContext
        _lines.value = lines
        nostrService.fetchMissingProfiles(lines.take(_shown.value + SHOW_STEP).flatMap { it.actors.take(6) }.distinct())
    }

    /**
     * The list came on screen ([arriving]) or left it. Arriving keeps the last
     * visit's time, so lines newer than it show as unread; both move the mark
     * to now and empty the account's switcher count. A first visit marks
     * nothing: everything would be "new".
     */
    fun visit(arriving: Boolean) {
        val owner = nostrService.activeHexPubkey
        val now = System.currentTimeMillis() / 1000
        val last = markAccountSeen(owner, now)
        if (arriving) _unreadSince.value = if (last > 0) last else now
    }

    /**
     * An account's Vault list was viewed: its seen mark moves to [now] and its
     * switcher count empties, together. Returns the mark it replaced (0 for a
     * first visit). The Vault list and the account chips both clear through here.
     */
    private fun markAccountSeen(hex: String, now: Long): Long {
        val last = seenStore.activitySeenAt(hex)
        seenStore.markActivitySeen(hex, now)
        accountUnread.markSeen(hex)
        return last
    }

    /**
     * A chip was picked: each other account it shows counts as viewed, the way
     * opening that account's Vault list would, then its lines load.
     */
    fun pickAccountChip(chip: VaultAccountChip) {
        val me = _activeHex.value
        val now = System.currentTimeMillis() / 1000
        val since = _otherUnreadSince.value.toMutableMap()
        for (hex in VaultAccountChips.accounts(chip, accountHexes.value)) {
            if (hex == me) continue
            val last = markAccountSeen(hex, now)
            // A first visit marks nothing: everything would be "new".
            since[hex] = if (last > 0) last else now
        }
        _otherUnreadSince.value = since
        _accountChip.value = if (VaultAccountChips.isDefault(chip, me)) null else chip
        loadOtherAccounts()
    }

    /** A line for [account] was opened: that account's count empties. */
    fun openedLine(account: String) {
        if (account != _activeHex.value) markAccountSeen(account, System.currentTimeMillis() / 1000)
    }

    /**
     * A line for another account opens as that account: switch first, so a
     * reply or like from the opened note signs with the right key, as a
     * tapped notification does. Then [open] runs.
     */
    fun openLineAs(account: String, open: () -> Unit) {
        val config = configStore.config.value
        val npubs = config.allAccountNpubs().mapNotNull { npub -> nostrService.npubToHex(npub)?.lowercase()?.let { it to npub } }.toMap()
        val npub = VaultAccountChips.switchTarget(account, _activeHex.value, npubs)
        if (npub == null) {
            open()
            return
        }
        viewModelScope.launch {
            configStore.switchActiveAccount(npub)
            open()
        }
    }

    private fun resetAccountChip() {
        otherJob?.cancel()
        _accountChip.value = null
        _otherLines.value = emptyMap()
        _otherUnreadSince.value = emptyMap()
        _otherLoading.value = false
    }

    /**
     * Reads the picked chip's other accounts from the same relays and builds
     * their lines with the same rules as the active account's. The device's
     * relay serves every account, so nothing else needs asking.
     */
    fun loadOtherAccounts() {
        val me = _activeHex.value
        val accounts = accountHexes.value
        val chip = VaultAccountChips.resolve(_accountChip.value, accounts, me)
        val wanted = VaultAccountChips.accounts(chip, accounts).filter { it != me }
        otherJob?.cancel()
        if (wanted.isEmpty()) {
            _otherLoading.value = false
            return
        }
        val gen = generation
        _otherLoading.value = _otherLines.value.isEmpty()
        otherJob = viewModelScope.launch {
            val built = wanted.map { hex -> async { hex to linesFor(hex) } }.awaitAll()
            if (gen != generation) return@launch
            _otherLines.value = _otherLines.value + built
            _otherLoading.value = false
            nostrService.fetchMissingProfiles(built.flatMap { (_, lines) -> lines.take(SHOW_STEP).flatMap { it.actors.take(6) } }.distinct())
        }
    }

    private suspend fun linesFor(hex: String): List<VaultActivity> {
        val raw = runCatching {
            nostrService.queryRawEvents(
                listOf(
                    """{"kinds":${kindsJson(VaultMode.RELAY_TAB_NOTE_KINDS)},"authors":["$hex"],"limit":$PAGE}""",
                    """{"kinds":${kindsJson(TAGGED_KINDS)},"#p":["$hex"],"limit":$PAGE}""",
                ),
                relays(), QUERY_TIMEOUT_MS,
            )
        }.getOrDefault(emptyList())
        val events = raw.mapNotNull(::parse).filter { keepsZap(it) }.distinctBy { it.id }
        return withContext(Dispatchers.Default) {
            val config = configStore.config.value
            val npub = config.allAccountNpubs().firstOrNull { nostrService.npubToHex(it)?.lowercase() == hex }
            val blocked = npub?.let { config.blockedFor(it) }.orEmpty().mapNotNull { nostrService.npubToHex(it) }.toSet()
            val whitelist = config.whitelistedNpubs?.mapNotNull { nostrService.npubToHex(it) }?.toSet().orEmpty()
            val trusted = feedService.relayTabTrustedPubkeys()
            val news = runCatching { FollowerSnapshot.parse(HavenBridge.getFollowers(hex)) }.getOrNull()
                ?.current.orEmpty().filter { it.isNews }.map { VaultActivity.Follow(it.pubkey, it.followedAt) }
            VaultActivity.build(
                events = events,
                owner = hex,
                noteKinds = VaultMode.RELAY_TAB_NOTE_KINDS,
                follows = news,
                isBlocked = { it in blocked },
                isOutside = { VaultContentFilter.isOutside(it, hex, whitelist, trusted) },
            )
        }
    }

    /** Followers seen here, as on the Followers list. */
    fun markFollowersSeen() = seenStore.markSeen(nostrService.activeHexPubkey)

    private fun kindsJson(kinds: Set<Int>) = kinds.sorted().joinToString(",", "[", "]")
}

/** The "Vault" list, with the tab's pill and Vault button (as the other lists). */
@OptIn(ExperimentalMaterial3Api::class)
@Composable
internal fun VaultActivityScreen(
    activity: VaultActivityViewModel,
    zapsOnly: Boolean,
    newModes: Set<VaultMode>,
    dashboardColor: Color,
    onSelect: (VaultMode) -> Unit,
    onOpenDashboard: () -> Unit,
    /** A line was tapped; the flag is true when it is for an account you are not on. */
    onOpenLine: (VaultActivity, Boolean) -> Unit,
) {
    val colors = LocalNostrVaultColors.current
    val all by activity.lines.collectAsState()
    val shownCount by activity.shown.collectAsState()
    val hasLoadedOnce by activity.hasLoadedOnce.collectAsState()
    val isRefreshing by activity.isRefreshing.collectAsState()
    val unreadSince by activity.unreadSince.collectAsState()
    val profiles by activity.profiles.collectAsState()
    val relayStatus by RelayForegroundService.relayStatus.collectAsState()
    val bootStatus by activity.relayBootStatus.collectAsState()
    // All, or only replies, mentions and quotes (the right pill's @).
    var filter by rememberSaveable { mutableStateOf(VaultActivityFilter.ALL) }
    // In Zaps Only mode, likes are hidden.
    val lines = remember(all, shownCount, zapsOnly, filter) {
        // Filtered before the page cap, so a page of likes doesn't hide the
        // mentions behind it.
        all.filter { filter.includes(it.kind) && !(zapsOnly && it.kind == VaultActivity.Kind.REACTION) }.take(shownCount)
    }
    // More than one account: "All · <acct> · <acct>" chips widen the list.
    val accountHexes by activity.accountHexes.collectAsState()
    val activeHex by activity.activeHex.collectAsState()
    val pickedChip by activity.accountChip.collectAsState()
    val otherLines by activity.otherLines.collectAsState()
    val otherUnreadSince by activity.otherUnreadSince.collectAsState()
    val otherLoading by activity.otherLoading.collectAsState()
    val unreadCounts by activity.accountUnreadState.collectAsState()
    val chips = remember(accountHexes, activeHex) { VaultAccountChips.chips(accountHexes, activeHex) }
    val currentChip = VaultAccountChips.resolve(pickedChip, accountHexes, activeHex)
    val others = !VaultAccountChips.isDefault(currentChip, activeHex)
    val rows: List<VaultAccountLine> = remember(lines, all, otherLines, currentChip, accountHexes, activeHex, shownCount, zapsOnly, filter) {
        if (!others) {
            lines.map { VaultAccountLine(activeHex, it) }
        } else {
            val perAccount = VaultAccountChips.accounts(currentChip, accountHexes).associateWith { hex ->
                (if (hex == activeHex) all else otherLines[hex].orEmpty())
                    .filter { filter.includes(it.kind) && !(zapsOnly && it.kind == VaultActivity.Kind.REACTION) }
            }
            VaultAccountChips.merge(perAccount, accountHexes, shownCount)
        }
    }
    val filterNote = rememberFilterNoteState()
    fun pick(next: VaultActivityFilter) {
        val shownAfter = if (next != filter) activity.filterChanged() else shownCount
        filter = next
        val matching = all.count { next.includes(it.kind) && !(zapsOnly && it.kind == VaultActivity.Kind.REACTION) }
        val count = minOf(matching, shownAfter)
        val capped = matching > shownAfter
        filterNote.show(
            if (next == VaultActivityFilter.MENTIONS) countNote(NostrVaultIcons.At, "Mentions", count, capped, "No mentions yet")
            else countNote(NostrVaultIcons.Layers, "Everything", count, capped, "Nothing new yet"),
        )
    }
    val listState = rememberLazyListState()

    val atEnd by remember {
        derivedStateOf {
            val last = listState.layoutInfo.visibleItemsInfo.lastOrNull()?.index ?: 0
            last >= listState.layoutInfo.totalItemsCount - 3
        }
    }
    LaunchedEffect(atEnd, rows.size) { if (atEnd && rows.isNotEmpty()) activity.loadMore() }

    ScrollCondenseEffect(
        scrollKey = listState,
        firstVisibleItemIndex = { listState.firstVisibleItemIndex },
        firstVisibleItemScrollOffset = { listState.firstVisibleItemScrollOffset },
    )
    LaunchedEffect(Unit) {
        TabReselect.of(Screen.Dashboard).collect { listState.animateScrollToItem(0) }
    }
    // New lines (a refresh on coming back to the tab, a tick) land above the
    // top line: show them rather than keep the old top line in place.
    RevealNewestEffect(listState) { rows.map { if (others) it.key else it.line.id } }

    GlassScaffold(
        toolbar = {
            Column {
                Row(
                    verticalAlignment = Alignment.CenterVertically,
                    modifier = Modifier
                        .fillMaxWidth()
                        .statusBarsPadding()
                        .padding(horizontal = 12.dp, vertical = 8.dp),
                ) {
                    VaultModePill(
                        mode = VaultMode.ACTIVITY,
                        zapsOnly = zapsOnly,
                        newModes = newModes,
                        onSelect = onSelect,
                        onOpenDashboard = onOpenDashboard,
                        modifier = Modifier.tutorialAnchor(TutorialContent.VAULT_MODES),
                    )
                    Spacer(Modifier.weight(1f))
                    // Messages | All · @, as bare icons; the note says what a tap picked.
                    VaultRightPill {
                        IconFilterButton(
                            icon = NostrVaultIcons.Layers,
                            contentDescription = "All",
                            isSelected = filter == VaultActivityFilter.ALL,
                            onClick = { pick(VaultActivityFilter.ALL) },
                        )
                        IconFilterButton(
                            icon = NostrVaultIcons.At,
                            contentDescription = "Mentions",
                            isSelected = filter == VaultActivityFilter.MENTIONS,
                            onClick = { pick(VaultActivityFilter.MENTIONS) },
                        )
                    }
                }
                if (chips.isNotEmpty()) {
                    AccountChipRow(
                        chips = chips,
                        selected = currentChip,
                        activeHex = activeHex,
                        profiles = profiles,
                        counts = unreadCounts,
                        onPick = activity::pickAccountChip,
                        modifier = Modifier.padding(bottom = 8.dp),
                    )
                }
            }
        },
        floatingActionButton = {
            // FoldBlocked alone reads the fold: its halfway flip never recomposes
            // the button (#1437).
            FoldBlocked(whenFolded = true, modifier = Modifier.chromeFab()) {
                Surface(
                    onClick = onOpenDashboard,
                    modifier = Modifier
                        .floatingRowButton()
                        .tutorialAnchor(TutorialContent.VAULT_RELAY),
                    color = dashboardColor,
                    shape = CircleShape,
                    shadowElevation = 8.dp,
                ) {
                    Row(
                        verticalAlignment = Alignment.CenterVertically,
                        modifier = Modifier
                            .height(FloatingButtonRow.buttonHeight)
                            .padding(horizontal = 18.dp),
                    ) {
                        Icon(NostrVaultIcons.TabVault, contentDescription = null, tint = PrimaryText, modifier = Modifier.size(18.dp))
                        Spacer(Modifier.width(6.dp))
                        Text("Vault", color = PrimaryText, fontSize = 14.sp, fontWeight = FontWeight.Bold)
                    }
                }
            }
        },
    ) { padding ->
        PullToRefreshBox(
            isRefreshing = isRefreshing && hasLoadedOnce,
            onRefresh = {
                runCatching { HavenBridge.requestRelaySync() }
                activity.refresh()
            },
            modifier = Modifier.fillMaxSize(),
        ) {
            val booting = relayStatus != RelayForegroundService.RelayStatus.RUNNING
            when {
                rows.isEmpty() && (
                    if (others) otherLoading || (currentChip == VaultAccountChip.All && !hasLoadedOnce)
                    else !hasLoadedOnce || isRefreshing || booting
                    ) -> Column(
                    horizontalAlignment = Alignment.CenterHorizontally,
                    verticalArrangement = Arrangement.Center,
                    modifier = Modifier.fillMaxSize().padding(top = padding.calculateTopPadding()),
                ) {
                    CircularProgressIndicator(color = colors.primary, modifier = Modifier.size(32.dp))
                    Spacer(Modifier.height(16.dp))
                    Text(
                        if (booting) bootStatus.ifBlank { "Starting relay..." } else "Loading your vault...",
                        color = PrimaryText, fontSize = 18.sp, fontWeight = FontWeight.Bold,
                    )
                }
                rows.isEmpty() -> Column(
                    horizontalAlignment = Alignment.CenterHorizontally,
                    verticalArrangement = Arrangement.Center,
                    modifier = Modifier.fillMaxSize().padding(top = padding.calculateTopPadding()),
                ) {
                    Icon(NostrVaultIcons.Activity, contentDescription = null, tint = colors.primary, modifier = Modifier.size(48.dp))
                    Spacer(Modifier.height(16.dp))
                    Text(if (filter == VaultActivityFilter.MENTIONS) "No mentions yet" else "Nothing new yet", color = PrimaryText, fontSize = 18.sp, fontWeight = FontWeight.Bold)
                    Spacer(Modifier.height(8.dp))
                    Text(
                        if (filter == VaultActivityFilter.MENTIONS) "Replies, mentions and quotes land here"
                        else "Replies, likes, zaps and new followers land here",
                        color = SecondaryText, fontSize = 13.sp,
                        fontFamily = androidx.compose.ui.text.font.FontFamily.Monospace,
                        textAlign = androidx.compose.ui.text.style.TextAlign.Center,
                        modifier = Modifier.padding(horizontal = 24.dp),
                    )
                }
                else -> LazyColumn(
                    state = listState,
                    contentPadding = PaddingValues(
                        top = padding.calculateTopPadding(),
                        bottom = padding.calculateBottomPadding() + 88.dp,
                    ),
                    verticalArrangement = Arrangement.spacedBy(10.dp),
                    modifier = Modifier.fillMaxSize(),
                ) {
                    items(rows, key = { if (others) it.key else it.line.id }) { row ->
                        val line = row.line
                        val isOther = row.account != activeHex
                        val since = if (isOther) otherUnreadSince[row.account] ?: Long.MAX_VALUE else unreadSince
                        VaultActivityRow(
                            line = line,
                            isUnread = line.createdAt > since,
                            profiles = profiles,
                            account = if (others) row.account else null,
                            onClick = {
                                activity.openedLine(row.account)
                                activity.openLineAs(row.account) { onOpenLine(line, isOther) }
                            },
                            modifier = Modifier.padding(horizontal = 16.dp),
                        )
                    }
                }
            }
        }
    }
}

private const val AVATAR_LIMIT = 6

/** One notification-style line: what happened, who did it, what it was about. */
@Composable
private fun VaultActivityRow(
    line: VaultActivity,
    isUnread: Boolean,
    profiles: Map<String, FeedProfile>,
    onClick: () -> Unit,
    modifier: Modifier = Modifier,
    /** The account the line is for, when the list holds more than one account's lines. */
    account: String? = null,
) {
    val colors = LocalNostrVaultColors.current
    val (icon, tint) = activityStyle(line.kind, colors.primary)
    val name: (String) -> String = { pubkey -> profiles[pubkey]?.bestName ?: ("npub…" + pubkey.takeLast(6)) }
    val who = VaultActivity.who(line.actors, name)
    val verb = activityVerb(line)
    val preview = remember(line.preview, profiles) { readablePreview(line.preview, name) }
    val shape = RoundedCornerShape(12.dp)
    Row(
        verticalAlignment = Alignment.Top,
        modifier = modifier
            .fillMaxWidth()
            .background(colors.primary.copy(alpha = if (isUnread) 0.10f else 0.03f), shape)
            .border(0.8.dp, colors.primary.copy(alpha = 0.18f), shape)
            .clickable(onClick = onClick)
            .padding(14.dp)
            .semantics(mergeDescendants = true) {
                contentDescription = (account?.let { "For ${name(it)}. " } ?: "") + "$who $verb. $preview"
                if (isUnread) stateDescription = "New"
            },
    ) {
        Box(
            contentAlignment = Alignment.Center,
            modifier = Modifier.size(34.dp).background(tint.copy(alpha = 0.15f), CircleShape),
        ) {
            Icon(icon, contentDescription = null, tint = tint, modifier = Modifier.size(17.dp))
        }
        Spacer(Modifier.width(12.dp))
        Column(Modifier.weight(1f)) {
            if (account != null) {
                // "For <account>": whose notification this is.
                Row(verticalAlignment = Alignment.CenterVertically) {
                    AvatarImage(
                        url = profiles[account]?.pictureURL,
                        pubkey = account,
                        size = 16.dp,
                        displayName = profiles[account]?.bestName,
                    )
                    Spacer(Modifier.width(5.dp))
                    Text(
                        "For ${name(account)}",
                        color = SecondaryText, fontSize = 12.sp, fontWeight = FontWeight.SemiBold,
                        maxLines = 1, overflow = TextOverflow.Ellipsis,
                    )
                }
                Spacer(Modifier.height(8.dp))
            }
            Row(verticalAlignment = Alignment.CenterVertically) {
                Row(Modifier.weight(1f)) {
                    line.actors.take(AVATAR_LIMIT).forEachIndexed { index, pubkey ->
                        val profile = profiles[pubkey]
                        AvatarImage(
                            url = profile?.pictureURL,
                            pubkey = pubkey,
                            size = 30.dp,
                            displayName = profile?.bestName,
                            // A ring keeps overlapping faces apart (iOS).
                            modifier = Modifier.offset(x = (-8 * index).dp).border(2.dp, SecondaryGroupedBg, CircleShape),
                        )
                    }
                    if (line.actors.size > AVATAR_LIMIT) {
                        Text(
                            "+${line.actors.size - AVATAR_LIMIT}",
                            color = SecondaryText, fontSize = 11.sp, fontWeight = FontWeight.Bold,
                            modifier = Modifier
                                .align(Alignment.CenterVertically)
                                .offset(x = (-8 * AVATAR_LIMIT + 6).dp),
                        )
                    }
                }
                Text(RelativeTime.abbreviated(line.createdAt, System.currentTimeMillis() / 1000), color = SecondaryText, fontSize = 12.sp, fontWeight = FontWeight.Medium)
                if (isUnread) {
                    Spacer(Modifier.width(8.dp))
                    Box(Modifier.size(8.dp).background(colors.primary, CircleShape))
                }
            }
            Spacer(Modifier.height(8.dp))
            // A custom emoji reaction draws its image (NIP-30).
            val emojiContent = remember(line.customEmojis) { customEmojiInlineContent(line.customEmojis) }
            Text(
                buildAnnotatedString {
                    withStyle(SpanStyle(fontWeight = FontWeight.Bold)) { append(who) }
                    append(" ")
                    appendTextWithEmoji(verb, line.customEmojis)
                },
                color = PrimaryText,
                fontSize = 15.sp,
                inlineContent = emojiContent,
            )
            if (preview.isNotEmpty()) {
                Spacer(Modifier.height(8.dp))
                if (line.aboutYourPost) {
                    // Your own post, when they only reacted to it: quieter and
                    // behind a rule, so the two never read alike.
                    Row(Modifier.height(IntrinsicSize.Min)) {
                        Box(
                            Modifier
                                .width(3.dp)
                                .fillMaxHeight()
                                .background(tint.copy(alpha = 0.5f), CircleShape),
                        )
                        Spacer(Modifier.width(10.dp))
                        Text(preview, color = SecondaryText, fontSize = 14.sp, maxLines = 2, overflow = TextOverflow.Ellipsis)
                    }
                } else {
                    Text(preview, color = PrimaryText, fontSize = 15.sp, maxLines = 4, overflow = TextOverflow.Ellipsis)
                }
            }
            if (line.images.isNotEmpty()) {
                Spacer(Modifier.height(8.dp))
                VaultActivityThumbnails(line.images)
            }
        }
    }
}

private fun activityStyle(kind: VaultActivity.Kind, primary: Color): Pair<ImageVector, Color> = when (kind) {
    VaultActivity.Kind.REPLY -> NostrVaultIcons.Reply to primary
    VaultActivity.Kind.MENTION -> NostrVaultIcons.At to primary
    VaultActivity.Kind.QUOTE -> NostrVaultIcons.Quote to InfoBlue
    VaultActivity.Kind.REACTION -> NostrVaultIcons.HeartFilled to LikeRed
    VaultActivity.Kind.REPOST -> NostrVaultIcons.Repost to RepostGreen
    VaultActivity.Kind.ZAP -> NostrVaultIcons.Zap to ZapOrange
    VaultActivity.Kind.ARTICLE -> NostrVaultIcons.Articles to primary
    VaultActivity.Kind.HIGHLIGHT -> NostrVaultIcons.Highlights to WarningYellow
    VaultActivity.Kind.FOLLOW -> NostrVaultIcons.PersonAdd to primary
}

/** The iPhone's words for each line. */
private fun activityVerb(line: VaultActivity): String = when (line.kind) {
    VaultActivity.Kind.REPLY -> "replied to you"
    VaultActivity.Kind.MENTION -> "mentioned you"
    VaultActivity.Kind.QUOTE -> "quoted your note"
    VaultActivity.Kind.REACTION -> {
        val emojis = reactionEmojiSummary(line.emojis, limit = 3, customShortcodes = line.customEmojis.keys)
        if (emojis == "❤️") "liked your note" else "reacted $emojis to your note"
    }
    VaultActivity.Kind.REPOST -> "reposted your note"
    VaultActivity.Kind.ZAP -> {
        val sats = NumberFormat.getIntegerInstance().format(line.sats)
        if (line.openId == null) "zapped you $sats sats" else "zapped your note $sats sats"
    }
    VaultActivity.Kind.ARTICLE -> "tagged you in an article"
    VaultActivity.Kind.HIGHLIGHT -> "highlighted you"
    VaultActivity.Kind.FOLLOW -> "followed you"
}

/**
 * The preview with `nostr:` links made readable: people become @names,
 * links to posts drop out (a one-line preview can't show them).
 */
private fun readablePreview(preview: String, name: (String) -> String): String {
    if (!preview.contains("nostr:")) return preview
    return preview.split(" ").mapNotNull { word ->
        if (!word.startsWith("nostr:")) return@mapNotNull word
        val id = word.removePrefix("nostr:").trim { !it.isLetterOrDigit() }
        val pubkey = when {
            id.startsWith("npub1") -> runCatching { HavenBridge.decodeNpub(id) }.getOrNull()
            id.startsWith("nprofile1") -> runCatching { HavenBridge.decodeNprofilePubkey(id) }.getOrNull()
            else -> null
        }
        pubkey?.let { "@" + name(it) }
    }.joinToString(" ")
}
