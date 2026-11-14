package com.nostrvault.ui.screens

import com.nostrvault.ui.components.rememberFilterNoteState
import com.nostrvault.ui.components.countNote
import com.nostrvault.ui.components.VaultRightPill
import com.nostrvault.data.model.VaultActivityFilter
import androidx.compose.runtime.setValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.saveable.rememberSaveable
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.PaddingValues
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.statusBarsPadding
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.items
import androidx.compose.foundation.lazy.rememberLazyListState
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.material3.CircularProgressIndicator
import androidx.compose.material3.ExperimentalMaterial3Api
import androidx.compose.material3.Icon
import androidx.compose.material3.Surface
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.collectAsState
import androidx.compose.runtime.derivedStateOf
import androidx.compose.runtime.getValue
import androidx.compose.runtime.remember
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.semantics.contentDescription
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import androidx.lifecycle.ViewModel
import androidx.lifecycle.viewModelScope
import com.nostrvault.data.local.ConfigStore
import com.nostrvault.data.local.FollowersSeenStore
import com.nostrvault.data.model.FeedProfile
import com.nostrvault.data.model.FollowerSnapshot
import com.nostrvault.data.model.VaultOtherAccounts
import com.nostrvault.data.model.VaultActivity
import com.nostrvault.data.model.AccountUnread
import com.nostrvault.data.model.VaultAccountChip
import com.nostrvault.data.model.VaultAccountChips
import com.nostrvault.data.model.VaultAccountLine
import com.nostrvault.data.model.VaultContentFilter
import com.nostrvault.data.model.VaultMode
import com.nostrvault.data.model.VaultNoteScope
import com.nostrvault.data.model.VaultOutsideFold
import com.nostrvault.relay.HavenBridge
import com.nostrvault.relay.RelayForegroundService
import com.nostrvault.service.FeedService
import com.nostrvault.service.NostrService
import com.nostrvault.service.ZapValidationService
import com.nostrvault.tutorials.TutorialContent
import com.nostrvault.tutorials.tutorialAnchor
import com.nostrvault.ui.components.GlassScaffold
import com.nostrvault.ui.components.ScrollCondenseEffect
import com.nostrvault.ui.components.chromeFab
import com.nostrvault.ui.components.FoldBlocked
import com.nostrvault.ui.navigation.FloatingButtonRow
import com.nostrvault.ui.navigation.FloatingButtonRow.floatingRowButton
import com.nostrvault.ui.navigation.Screen
import com.nostrvault.ui.navigation.TabReselect
import com.nostrvault.ui.theme.LocalNostrVaultColors
import com.nostrvault.ui.theme.NostrVaultIcons
import com.nostrvault.ui.theme.PrimaryText
import com.nostrvault.ui.theme.SecondaryText
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
import javax.inject.Inject
import com.nostrvault.relay.VaultStoreRead
import com.nostrvault.data.model.VaultListSwap
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

    // One swap per refresh (VaultListSwap): reads running now, and since when
    // a built list has been held back.
    private val readsRunning = java.util.concurrent.atomic.AtomicInteger(0)
    private var heldSince: Long? = null

    /**
     * Refreshes run one at a time; asks during one become one more after it.
     * At launch the engine start, the relay's port and the screen's resume
     * each ask within a second: one read of the whole window and one top-up,
     * not three whole windows parsed side by side.
     */
    private val refreshRequests = kotlinx.coroutines.channels.Channel<Unit>(kotlinx.coroutines.channels.Channel.CONFLATED)

    init {
        viewModelScope.launch {
            for (request in refreshRequests) {
                // One failed read must not end every later one.
                try {
                    refreshOnce()
                } catch (e: kotlinx.coroutines.CancellationException) {
                    throw e
                } catch (e: Exception) {
                    android.util.Log.w("VaultActivityVM", "refresh failed: ${e.message}")
                }
            }
        }
    }

    private val _lines = MutableStateFlow<List<VaultActivity>>(emptyList())
    /** Every line, newest first; the list shows the first [shown]. */
    val lines: StateFlow<List<VaultActivity>> = _lines.asStateFlow()

    private val _outsideLines = MutableStateFlow<List<VaultActivity>>(emptyList())
    /**
     * What [lines] leaves out: posts tagging you from outside your network,
     * newest first (··· › Outside your web). This account only.
     */
    val outsideLines: StateFlow<List<VaultActivity>> = _outsideLines.asStateFlow()

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

    /** A chip just picked whose accounts are still being read: its ring shows, the list stays. */
    private val _pendingChip = MutableStateFlow<VaultAccountChip?>(null)
    val pendingChip: StateFlow<VaultAccountChip?> = _pendingChip.asStateFlow()

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

    /** Each other account's events, held across reads and account switches (VaultOtherAccounts). */
    private val otherEvents = HashMap<String, Map<String, VaultActivity.Event>>()
    private val otherEventsMutex = Mutex()

    init {
        RelayForegroundService.newsDot.setJudged(true)
        // The rows from the store as soon as the engine is up, before its port
        // is (VaultStoreRead); the read below once it takes connections tops up.
        viewModelScope.launch {
            RelayForegroundService.engineStarts.collect { if (it > 0) refresh() }
        }
        // As the Vault's lists: load once the local relay takes connections.
        viewModelScope.launch {
            RelayForegroundService.readyForConnections.collect { ready ->
                if (ready) {
                    refresh()
                    loadOtherAccounts()
                }
            }
        }
        // The relay's importer writes inbound events straight to its DBs; the
        // log poller's tick says when, so they show up live.
        viewModelScope.launch {
            RelayForegroundService.inboxActivityTick.drop(1).collectLatest {
                delay(1_500)
                refresh()
                loadOtherAccounts()
            }
        }
        // Your accounts tagging each other came into the list or left it.
        viewModelScope.launch {
            configStore.config.map { it.notifyOwnAccountTags }.distinctUntilChanged().drop(1).collect {
                scheduleRebuild()
                // Rebuilt from the held events with the new rule, in place.
                loadOtherAccounts()
            }
        }
        viewModelScope.launch {
            configStore.accountSwitches.collect {
                generation++
                eventsMutex.withLock { events.clear() }
                noOlder = false
                _lines.value = emptyList()
                _outsideLines.value = emptyList()
                _shown.value = FIRST_SHOW
                _hasLoadedOnce.value = false
                _unreadSince.value = Long.MAX_VALUE
                follows = emptyList()
                _activeHex.value = nostrService.activeHexPubkey.lowercase()
                heldSince = null
                resetAccountChip()
                refresh()
                loadOtherAccounts()
            }
        }
        // An account added or removed: its list is read ahead too.
        viewModelScope.launch {
            accountHexes.drop(1).collect { loadOtherAccounts() }
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
    private fun relays(): List<String> = localRelays() + macRelays()

    /** This device's outbox and inbox: what the store read (VaultStoreRead) covers. */
    private fun localRelays(): List<String> {
        val config = configStore.config.value
        return listOfNotNull(config.nostrURL, config.localInboxURL)
    }

    /** The Mac relay's outbox and inbox, which the store can't see. */
    private fun macRelays(): List<String> {
        val mac = configStore.config.value.macRelayWssURL
        return if (mac.isEmpty()) emptyList() else listOf(mac, "$mac/inbox")
    }

    /** New events since the newest held (pull to refresh, a tick, a visit). */
    fun refresh() {
        refreshRequests.trySend(Unit)
    }

    private suspend fun refreshOnce() {
        val owner = nostrService.activeHexPubkey
        if (owner.isEmpty()) return
        val newest = eventsMutex.withLock { events.values.maxOfOrNull { it.createdAt } }
        val since = VaultActivity.refreshSince(newest, VaultActivity.nowSeconds())
            ?.let { ",\"since\":$it" } ?: ""
        // The dot's lists the relay proposed before this read: it settles them.
        val asked = RelayForegroundService.newsDot.proposed()
        readsRunning.incrementAndGet()
        _isRefreshing.value = true
        com.nostrvault.relay.StartupMarks.markOnce("vault read asked")
        // Held until the read that counts is done: the store read when it
        // answers (the Mac relay's socket read after it only tops up and
        // never holds the list), else the socket read of every relay.
        var holding = true
        suspend fun release() {
            if (!holding) return
            holding = false
            val running = readsRunning.decrementAndGet()
            _isRefreshing.value = running > 0
            _hasLoadedOnce.value = true
            // The read is done: the list built meanwhile goes up in one swap.
            if (running == 0) scheduleRebuild()
        }
        val filters = listOf(
            """{"kinds":${kindsJson(VaultMode.RELAY_TAB_NOTE_KINDS)},"authors":["$owner"]$since,"limit":$PAGE}""",
            """{"kinds":${kindsJson(TAGGED_KINDS)},"#p":["$owner"]$since,"limit":$PAGE}""",
        )
        try {
            read(filters) { release() }
        } finally {
            release()
            settleNews(asked, owner)
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
                if (filters.isEmpty() || read(filters) == 0) noOlder = true
                _shown.value += SHOW_STEP
            } finally {
                _isLoadingOlder.value = false
            }
        }
    }

    /**
     * Runs [filters]: this device's outbox and inbox straight from the store
     * (VaultStoreRead), then the Mac relay over the socket; when the store
     * can't answer, every relay over the socket as before. [storeDone] runs
     * once the store's rows are kept. Returns how many events were new.
     */
    private suspend fun read(filters: List<String>, storeDone: suspend () -> Unit = {}): Int {
        val gen = generation
        val stored = withContext(Dispatchers.IO) { VaultStoreRead.query(filters) }
            ?: return fetch(filters, relays())
        com.nostrvault.relay.StartupMarks.markOnce("vault store read", "vault store read ${stored.size}")
        val added = keep(stored, gen)
        storeDone()
        val mac = macRelays()
        return if (mac.isEmpty()) added else added + fetch(filters, mac)
    }

    /** Runs [filters] over the socket on [relays] and keeps what came back. Returns how many events were new. */
    private suspend fun fetch(filters: List<String>, relays: List<String>): Int {
        val gen = generation
        val raw = runCatching { nostrService.queryRawEvents(filters, relays, QUERY_TIMEOUT_MS) }.getOrDefault(emptyList())
        com.nostrvault.relay.StartupMarks.markOnce("vault read back")
        return keep(raw, gen)
    }

    /** Keeps the valid events of [raw] if no switch came since [gen]. Returns how many were new. */
    private suspend fun keep(raw: List<JsonObject>, gen: Int): Int {
        val now = VaultActivity.nowSeconds()
        val valid = raw.mapNotNull(::parse).filter { !VaultActivity.isFuture(it.createdAt, now) && keepsZap(it) }
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

    /** The follows the Followers list marks as news, from the relay's ledger: in-web only. */
    fun setFollowers(snapshot: FollowerSnapshot?) {
        val news = snapshot?.current.orEmpty().filter { it.isNewsInWeb }.map { VaultActivity.Follow(it.pubkey, it.followedAt) }
        if (news == follows) return
        follows = news
        scheduleRebuild()
    }

    /** The kind of a held event, so an article opens as one. */
    fun kindOf(id: String): Int? = events[id]?.kind

    private fun scheduleRebuild() {
        rebuildJob?.cancel()
        rebuildJob = viewModelScope.launch {
            // Nothing on screen yet: build now. The 150 ms gathers a burst
            // into one rebuild only once there is a list to keep steady.
            if (_lines.value.isNotEmpty()) delay(150)
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
        val quietOwn = ownAccountTagRule(config)
        val snapshot = eventsMutex.withLock { events.values.toList() }
        val lines = VaultActivity.build(
            events = snapshot,
            owner = owner,
            noteKinds = VaultMode.RELAY_TAB_NOTE_KINDS,
            follows = follows,
            isBlocked = { it in blocked || quietOwn(it, owner) },
            isOutside = { VaultContentFilter.isOutside(it, owner, whitelist, trusted) },
            foldsOutsideLikes = true,
        )
        val outside = VaultActivity.build(
            events = snapshot,
            owner = owner,
            noteKinds = VaultMode.RELAY_TAB_NOTE_KINDS,
            isBlocked = { it in blocked || quietOwn(it, owner) },
            isOutside = { VaultContentFilter.isOutside(it, owner, whitelist, trusted) },
            outsideOnly = true,
            foldsOutsideLikes = true,
        )
        if (gen != generation) return@withContext
        if (!publishesNow(snapshot.isNotEmpty())) return@withContext
        if (lines.isNotEmpty()) com.nostrvault.relay.StartupMarks.markOnce("vault rows shown")
        _lines.value = lines
        _outsideLines.value = outside
        nostrService.fetchMissingProfiles(
            (lines.take(_shown.value + SHOW_STEP) + outside.take(_shown.value)).flatMap { it.actors.take(6) }.distinct(),
        )
    }

    /**
     * Whether the list just built goes on screen now (VaultListSwap): while a
     * read runs, or nothing was read yet, the list on screen stays and the new
     * one goes up when the read ends or the cap passes.
     */
    @Synchronized
    private fun publishesNow(hasEvents: Boolean): Boolean {
        val refreshing = readsRunning.get() > 0 || (!hasEvents && !_hasLoadedOnce.value)
        val now = System.currentTimeMillis()
        if (!refreshing) {
            heldSince = null
        } else if (heldSince == null) {
            heldSince = now
            // Look again once the cap is up, in case the read never ends.
            viewModelScope.launch {
                delay(VaultListSwap.CAP_MS + 100)
                scheduleRebuild()
            }
        }
        return VaultListSwap.publishes(refreshing, heldSince?.let { now - it })
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
        if (VaultAccountChips.needsRead(chip, accountHexes.value, me, _otherLines.value.keys)) {
            // Keep the list on screen; switch when this chip's lines are read.
            _pendingChip.value = chip
            loadOtherAccounts(chip)
        } else {
            applyChip(chip)
            loadOtherAccounts()
        }
    }

    private fun applyChip(chip: VaultAccountChip) {
        _pendingChip.value = null
        _accountChip.value = if (VaultAccountChips.isDefault(chip, _activeHex.value)) null else chip
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
            com.nostrvault.ui.components.AccountSwitchFlash.show(account)
            open()
        }
    }

    private fun resetAccountChip() {
        otherJob?.cancel()
        _accountChip.value = null
        _pendingChip.value = null
        _otherLines.value = emptyMap()
        _otherUnreadSince.value = emptyMap()
        _otherLoading.value = false
    }

    /**
     * Reads every other account from the phone's own vault and builds their
     * lines with the same rules as the active account's, ahead of any tap, so
     * picking a chip only flips it (Logen 2026-11-14). Runs on each inbox tick,
     * after a switch and once the relay is up; each read tops up what is held.
     * [pick] is a chip picked before its accounts were ever read: the list on
     * screen stays (no spinner) and switches to it once the read is in. A plain
     * re-read while a pick waits still applies that pick, so it can't be left stuck.
     */
    fun loadOtherAccounts(pick: VaultAccountChip? = null) {
        val me = _activeHex.value
        val accounts = accountHexes.value
        val waiting = pick ?: _pendingChip.value
        val chip = VaultAccountChips.resolve(waiting ?: _accountChip.value, accounts, me)
        val wanted = VaultOtherAccounts.wanted(accounts, me)
        otherJob?.cancel()
        if (wanted.isEmpty()) {
            _otherLoading.value = false
            waiting?.let(::applyChip)
            return
        }
        val gen = generation
        // The spinner only for a picked chip with nothing to show yet.
        if (waiting == null) _otherLoading.value = !VaultAccountChips.isDefault(chip, me) &&
            VaultAccountChips.accounts(chip, accounts).any { it != me && it !in _otherLines.value }
        otherJob = viewModelScope.launch {
            val built = wanted.map { hex -> async { hex to linesFor(hex) } }.awaitAll()
            if (gen != generation) return@launch
            // Folded in quietly: an account whose lines did not change keeps them.
            val next = (_otherLines.value + built).filterKeys { it in wanted }
            if (next != _otherLines.value) _otherLines.value = next
            _otherLoading.value = false
            if (waiting != null && _pendingChip.value == waiting) applyChip(waiting)
            nostrService.fetchMissingProfiles(built.flatMap { (_, lines) -> lines.take(SHOW_STEP).flatMap { it.actors.take(6) } }.distinct())
        }
    }

    /**
     * [hex]'s lines: what is held, topped up from the phone's own vault since
     * the newest held (all of it the first time). Never the Mac relay: a chip
     * must not wait on a remote socket.
     */
    private suspend fun linesFor(hex: String): List<VaultActivity> {
        val now = VaultActivity.nowSeconds()
        val held = otherEventsMutex.withLock { otherEvents[hex].orEmpty() }
        val since = VaultOtherAccounts.sinceClause(held.values, now)
        val config = configStore.config.value
        val raw = runCatching {
            nostrService.queryRawEvents(
                listOf(
                    """{"kinds":${kindsJson(VaultMode.RELAY_TAB_NOTE_KINDS)},"authors":["$hex"]$since,"limit":$PAGE}""",
                    """{"kinds":${kindsJson(TAGGED_KINDS)},"#p":["$hex"]$since,"limit":$PAGE}""",
                ),
                VaultOtherAccounts.localRelays(config.nostrURL, config.localInboxURL), QUERY_TIMEOUT_MS,
            )
        }.getOrDefault(emptyList())
        val fresh = raw.mapNotNull(::parse).filter { !VaultActivity.isFuture(it.createdAt, now) && keepsZap(it) }
        val events = otherEventsMutex.withLock {
            VaultOtherAccounts.fold(otherEvents[hex].orEmpty(), fresh).also { otherEvents[hex] = it }
        }.values.toList()
        return withContext(Dispatchers.Default) {
            val npub = config.allAccountNpubs().firstOrNull { nostrService.npubToHex(it)?.lowercase() == hex }
            val blocked = npub?.let { config.blockedFor(it) }.orEmpty().mapNotNull { nostrService.npubToHex(it) }.toSet()
            val whitelist = config.whitelistedNpubs?.mapNotNull { nostrService.npubToHex(it) }?.toSet().orEmpty()
            val trusted = feedService.trustedPubkeysFor(hex)
            val news = runCatching { FollowerSnapshot.parse(HavenBridge.getFollowers(hex)) }.getOrNull()
                ?.let { feedService.followersJudged(it, hex) }
                ?.current.orEmpty().filter { it.isNewsInWeb }.map { VaultActivity.Follow(it.pubkey, it.followedAt) }
            val quietOwn = ownAccountTagRule(config)
            VaultActivity.build(
                events = events,
                owner = hex,
                noteKinds = VaultMode.RELAY_TAB_NOTE_KINDS,
                follows = news,
                isBlocked = { it in blocked || quietOwn(it, hex) },
                isOutside = { VaultContentFilter.isOutside(it, hex, whitelist, trusted) },
                foldsOutsideLikes = true,
            )
        }
    }

    /**
     * (author, the account a line is for) → hidden as one of your accounts
     * tagging another, while "Notify me when my own accounts tag each other"
     * is off (AccountUnread.hidesOwnAccountTag).
     */
    private fun ownAccountTagRule(config: com.nostrvault.relay.HavenConfig): (String, String) -> Boolean {
        if (config.notifyOwnAccountTags) return { _, _ -> false }
        val accounts = config.allAccountNpubs().mapNotNull { nostrService.npubToHex(it)?.lowercase() }.toSet()
        return { author, owner -> AccountUnread.hidesOwnAccountTag(author, owner, accounts, notify = false) }
    }

    /** Followers seen here, as on the Followers list. */
    fun markFollowersSeen() = seenStore.markSeen(nostrService.activeHexPubkey)

    // ── Dot (VaultActivityNews) ──

    /** [mode] was on screen for the active account: the dot lights only for what comes after. */
    fun recordVisit(mode: VaultMode) {
        seenStore.markNewsVisit(nostrService.activeHexPubkey, VaultActivityNews.visited(mode).map { it.name })
    }

    /** A read for [owner] ended: of the lists proposed before it, the ones with news light. */
    private suspend fun settleNews(asked: Set<VaultMode>, owner: String) {
        if (asked.isEmpty()) return
        val held = eventsMutex.withLock { events.values.toList() }
        val own = accountHexes.value.toSet()
        RelayForegroundService.newsDot.settle(asked, owner) { mode ->
            VaultActivityNews.hasNews(held, mode, owner, own, seenStore.newsVisit(owner, mode.name))
        }
    }

    override fun onCleared() {
        RelayForegroundService.newsDot.setJudged(false)
        super.onCleared()
    }

    private fun kindsJson(kinds: Set<Int>) = kinds.sorted().joinToString(",", "[", "]")
}
