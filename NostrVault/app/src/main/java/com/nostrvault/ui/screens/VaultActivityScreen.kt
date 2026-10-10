package com.nostrvault.ui.screens

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
import com.nostrvault.ui.components.blockedWhen
import com.nostrvault.ui.components.chromeFab
import com.nostrvault.ui.components.formatTimestamp
import com.nostrvault.ui.components.reactionEmojiSummary
import com.nostrvault.ui.components.rememberChromeFolded
import com.nostrvault.ui.navigation.FloatingButtonRow
import com.nostrvault.ui.navigation.FloatingButtonRow.floatingRowButton
import com.nostrvault.ui.navigation.Screen
import com.nostrvault.ui.navigation.TabReselect
import com.nostrvault.ui.theme.LikeRed
import com.nostrvault.ui.theme.LocalNostrVaultColors
import com.nostrvault.ui.theme.NostrVaultIcons
import com.nostrvault.ui.theme.PrimaryText
import com.nostrvault.ui.theme.RepostGreen
import com.nostrvault.ui.theme.SecondaryText
import com.nostrvault.ui.theme.WarningYellow
import com.nostrvault.ui.theme.ZapOrange
import dagger.hilt.android.lifecycle.HiltViewModel
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.Job
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
) : ViewModel() {

    private companion object {
        const val PAGE = 500
        const val OLDER_PAGE = 200
        const val QUERY_TIMEOUT_MS = 8_000L
        const val SHOW_STEP = 50
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

    private val _shown = MutableStateFlow(SHOW_STEP)
    val shown: StateFlow<Int> = _shown.asStateFlow()

    private val _hasLoadedOnce = MutableStateFlow(false)
    val hasLoadedOnce: StateFlow<Boolean> = _hasLoadedOnce.asStateFlow()

    private val _isRefreshing = MutableStateFlow(false)
    val isRefreshing: StateFlow<Boolean> = _isRefreshing.asStateFlow()

    private val _isLoadingOlder = MutableStateFlow(false)

    /** Lines newer than this (unix seconds) arrived since your last visit. */
    private val _unreadSince = MutableStateFlow(Long.MAX_VALUE)
    val unreadSince: StateFlow<Long> = _unreadSince.asStateFlow()

    val profiles: StateFlow<Map<String, FeedProfile>> = nostrService.profiles

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
            }
        }
        viewModelScope.launch {
            configStore.accountSwitches.collect {
                generation++
                eventsMutex.withLock { events.clear() }
                noOlder = false
                _lines.value = emptyList()
                _shown.value = SHOW_STEP
                _hasLoadedOnce.value = false
                _unreadSince.value = Long.MAX_VALUE
                follows = emptyList()
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
        val parsed = raw.mapNotNull(::parse)
        val valid = parsed.filter { event ->
            // NIP-57: only a receipt from the publisher your LNURL names (as the Zaps list).
            if (event.kind != VaultActivity.ZAP_KIND) return@filter true
            val recipient = event.tags.firstOrNull { it.size >= 2 && it[0] == "p" }?.get(1) ?: return@filter false
            ZapValidationService.isValidReceipt(event.pubkey, recipient, nostrService.profiles.value)
        }
        if (gen != generation) return 0
        val added = eventsMutex.withLock { valid.count { events.put(it.id, it) == null } }
        if (added > 0 || !_hasLoadedOnce.value) scheduleRebuild()
        return added
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
        return VaultActivity.Event(id, pubkey, kind, createdAt, content, tags)
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
     * to now. A first visit marks nothing: everything would be "new".
     */
    fun visit(arriving: Boolean) {
        val owner = nostrService.activeHexPubkey
        val now = System.currentTimeMillis() / 1000
        if (arriving) {
            val last = seenStore.activitySeenAt(owner)
            _unreadSince.value = if (last > 0) last else now
        }
        seenStore.markActivitySeen(owner, now)
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
    onOpenLine: (VaultActivity) -> Unit,
) {
    val colors = LocalNostrVaultColors.current
    val all by activity.lines.collectAsState()
    val shownCount by activity.shown.collectAsState()
    val hasLoadedOnce by activity.hasLoadedOnce.collectAsState()
    val isRefreshing by activity.isRefreshing.collectAsState()
    val unreadSince by activity.unreadSince.collectAsState()
    val profiles by activity.profiles.collectAsState()
    val relayStatus by RelayForegroundService.relayStatus.collectAsState()
    // In Zaps Only mode, likes are hidden.
    val lines = remember(all, shownCount, zapsOnly) {
        (if (zapsOnly) all.filter { it.kind != VaultActivity.Kind.REACTION } else all).take(shownCount)
    }
    val listState = rememberLazyListState()

    val atEnd by remember {
        derivedStateOf {
            val last = listState.layoutInfo.visibleItemsInfo.lastOrNull()?.index ?: 0
            last >= listState.layoutInfo.totalItemsCount - 3
        }
    }
    LaunchedEffect(atEnd, lines.size) { if (atEnd && lines.isNotEmpty()) activity.loadMore() }

    ScrollCondenseEffect(
        scrollKey = listState,
        firstVisibleItemIndex = { listState.firstVisibleItemIndex },
        firstVisibleItemScrollOffset = { listState.firstVisibleItemScrollOffset },
    )
    LaunchedEffect(Unit) {
        TabReselect.of(Screen.Dashboard).collect { listState.animateScrollToItem(0) }
    }

    GlassScaffold(
        toolbar = {
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
            }
        },
        floatingActionButton = {
            val folded by rememberChromeFolded()
            Box(Modifier.chromeFab().blockedWhen(folded)) {
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
                lines.isEmpty() && (!hasLoadedOnce || isRefreshing || booting) -> Column(
                    horizontalAlignment = Alignment.CenterHorizontally,
                    verticalArrangement = Arrangement.Center,
                    modifier = Modifier.fillMaxSize().padding(top = padding.calculateTopPadding()),
                ) {
                    CircularProgressIndicator(color = colors.primary, modifier = Modifier.size(32.dp))
                    Spacer(Modifier.height(16.dp))
                    Text(
                        if (booting) "Starting relay..." else "Loading your vault...",
                        color = PrimaryText, fontSize = 18.sp, fontWeight = FontWeight.Bold,
                    )
                }
                lines.isEmpty() -> Column(
                    horizontalAlignment = Alignment.CenterHorizontally,
                    verticalArrangement = Arrangement.Center,
                    modifier = Modifier.fillMaxSize().padding(top = padding.calculateTopPadding()),
                ) {
                    Icon(NostrVaultIcons.Activity, contentDescription = null, tint = colors.primary, modifier = Modifier.size(48.dp))
                    Spacer(Modifier.height(16.dp))
                    Text("Nothing new yet", color = PrimaryText, fontSize = 18.sp, fontWeight = FontWeight.Bold)
                    Spacer(Modifier.height(8.dp))
                    Text(
                        "Replies, likes, zaps and new followers land here",
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
                    items(lines, key = { it.id }) { line ->
                        VaultActivityRow(
                            line = line,
                            isUnread = line.createdAt > unreadSince,
                            profiles = profiles,
                            onClick = { onOpenLine(line) },
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
                contentDescription = "$who $verb. $preview"
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
            Row(verticalAlignment = Alignment.CenterVertically) {
                Row(Modifier.weight(1f)) {
                    line.actors.take(AVATAR_LIMIT).forEachIndexed { index, pubkey ->
                        val profile = profiles[pubkey]
                        AvatarImage(
                            url = profile?.pictureURL,
                            pubkey = pubkey,
                            size = 30.dp,
                            displayName = profile?.bestName,
                            modifier = Modifier.offset(x = (-8 * index).dp),
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
                Text(formatTimestamp(line.createdAt), color = SecondaryText, fontSize = 12.sp, fontWeight = FontWeight.Medium)
                if (isUnread) {
                    Spacer(Modifier.width(8.dp))
                    Box(Modifier.size(8.dp).background(colors.primary, CircleShape))
                }
            }
            Spacer(Modifier.height(8.dp))
            Text(
                buildAnnotatedString {
                    withStyle(SpanStyle(fontWeight = FontWeight.Bold)) { append(who) }
                    append(" ")
                    append(verb)
                },
                color = PrimaryText,
                fontSize = 15.sp,
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
        }
    }
}

private fun activityStyle(kind: VaultActivity.Kind, primary: Color): Pair<ImageVector, Color> = when (kind) {
    VaultActivity.Kind.REPLY -> NostrVaultIcons.Reply to primary
    VaultActivity.Kind.MENTION -> NostrVaultIcons.At to primary
    VaultActivity.Kind.QUOTE -> NostrVaultIcons.Quote to primary
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
        val emojis = reactionEmojiSummary(line.emojis, limit = 3)
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
