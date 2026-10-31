package com.nostrvault.ui.screens.settings

import androidx.activity.compose.BackHandler
import androidx.compose.foundation.background
import androidx.compose.foundation.border
import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.*
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.items
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material3.*
import androidx.compose.runtime.*
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.semantics.contentDescription
import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.semantics.stateDescription
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.style.TextDecoration
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import androidx.hilt.lifecycle.viewmodel.compose.hiltViewModel
import androidx.lifecycle.ViewModel
import androidx.lifecycle.viewModelScope
import com.nostrvault.data.local.ConfigStore
import com.nostrvault.data.remote.LocalTls
import com.nostrvault.data.remote.WebSocketClient
import com.nostrvault.relay.DMInbox
import com.nostrvault.relay.HavenConfig
import com.nostrvault.relay.PublicRelayList
import com.nostrvault.relay.RelayBlocklist
import com.nostrvault.relay.RelayDraft
import com.nostrvault.relay.RelayMatrix
import com.nostrvault.relay.RelayMatrix.Job
import com.nostrvault.service.FeedService
import com.nostrvault.service.NostrService
import com.nostrvault.service.publishDMRelayList
import com.nostrvault.ui.theme.*
import dagger.hilt.android.lifecycle.HiltViewModel
import kotlinx.coroutines.CompletableDeferred
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.Job as CoroutineJob
import kotlinx.coroutines.delay
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.update
import kotlinx.coroutines.flow.asStateFlow
import kotlinx.coroutines.launch
import kotlinx.coroutines.withContext
import kotlinx.coroutines.withTimeoutOrNull
import okhttp3.Request
import okhttp3.Response
import okhttp3.WebSocket
import okhttp3.WebSocketListener
import javax.inject.Inject

/** How a relay answered the probe from this device. */
sealed class RelayProbeResult {
    data object Probing : RelayProbeResult()
    data class Answered(val milliseconds: Int) : RelayProbeResult()
    data object Unreachable : RelayProbeResult()

    companion object {
        /** Slower than this shows as "slow". */
        const val SLOW_MS = 500
    }
}

/**
 * Settings > Relays: every relay the owner uses on one screen, as a draft
 * (Logen 2026-10-31, option A; see [RelayDraft]). Dots, Remove and Add only
 * change the draft. Save writes it to the config and, after a confirm
 * sheet, publishes kind 10002 / 10050 from the Yours rows; App defaults,
 * Search and Import stay on this device. The Recommended page suggests
 * relays the follows write to and the fastest well-known relays; Never
 * connect blocks a relay and publishes kind 10006.
 */
@HiltViewModel
class RelayMatrixViewModel @Inject constructor(
    private val configStore: ConfigStore,
    private val nostrService: NostrService,
    private val feedService: FeedService,
) : ViewModel() {

    val config = configStore.config

    private val _results = MutableStateFlow<Map<String, RelayProbeResult>>(emptyMap())
    val results = _results.asStateFlow()

    /** Null until the published lists have been looked up. */
    private val _draft = MutableStateFlow<RelayDraft.State?>(null)
    val draft = _draft.asStateFlow()

    private val _notPublished = MutableStateFlow<List<String>>(emptyList())
    /** Lists the last Save kept on this device: the newest copy couldn't be read at Save. */
    val notPublished = _notPublished.asStateFlow()

    private var blockedJob: CoroutineJob? = null
    private var blockedPending = false

    data class FollowInfo(
        val suggestions: List<RelayMatrix.FollowSuggestion> = emptyList(),
        val withLists: Int = 0,
        val follows: Int = 0,
    )

    private val _follow = MutableStateFlow(FollowInfo())
    val follow = _follow.asStateFlow()

    init {
        viewModelScope.launch {
            val published = runCatching { nostrService.lookupOwnerRelayLists() }.getOrElse { RelayDraft.Published() }
            val cfg = configStore.config.value
            val state = RelayDraft.start(RelayMatrix.lists(cfg), published, pinned(cfg))
            _draft.value = state
            probe(RelayMatrix.needingProbe(state.layout.map { it.url }, _results.value.keys))
            refreshSuggestions()
        }
    }

    /** The lists the screen shows: the draft once loaded, else the config. */
    private fun currentLists(): RelayMatrix.Lists =
        _draft.value?.draft ?: RelayMatrix.lists(configStore.config.value)

    /** Walks every follow's relay list, so it runs when asked, not per frame. */
    fun refreshSuggestions() {
        val cfg = configStore.config.value
        val follows = feedService.followedPubkeys.value
        val outbox = nostrService.outboxRelays.value
        _follow.value = FollowInfo(
            suggestions = RelayMatrix.followSuggestions(
                follows, outbox, currentLists(), cfg.blockedRelays, pinned(cfg)),
            withLists = RelayMatrix.followsWithRelayLists(follows, outbox),
            follows = follows.size,
        )
    }

    /** Never connect: blocked now (kind 10006), out of the lists on Save. */
    fun block(url: String) {
        val cfg = configStore.config.value
        setBlocked(RelayMatrix.blocking(url, currentLists(), cfg.blockedRelays).second)
        edit { RelayDraft.remove(it, RelayMatrix.key(url)) }
    }

    fun unblock(url: String) = setBlocked(RelayMatrix.unblocking(url, configStore.config.value.blockedRelays))

    private fun setBlocked(blocked: List<String>) {
        if (blocked == configStore.config.value.blockedRelays) return
        configStore.update { it.copy(blockedRelays = blocked) }
        WebSocketClient.blocklistChanged()
        refreshSuggestions()
        blockedPending = true
        blockedJob?.cancel()
        blockedJob = viewModelScope.launch {
            delay(2_000)
            publishBlocked()
        }
    }

    private fun publishBlocked() {
        if (!blockedPending) return
        blockedPending = false
        nostrService.publishBlockedRelayList()
    }

    fun ownRelay(cfg: HavenConfig): String = cfg.macRelayWssURL

    fun pinned(cfg: HavenConfig): List<String> = listOf(cfg.macRelayWssURL, cfg.ownHavenDMInboxURL)

    /** Changes the draft; nothing is written until [save]. */
    fun edit(change: (RelayDraft.State) -> RelayDraft.State) {
        val state = _draft.value ?: return
        val next = change(state)
        if (next == state) return
        _draft.value = next
        // Only relays with no speed yet, so the timed rows keep their dots.
        probe(RelayMatrix.needingProbe(next.layout.map { it.url }, _results.value.keys))
    }

    fun toggle(key: String, job: Job) = edit { RelayDraft.toggle(it, key, job) }
    fun remove(key: String) = edit { RelayDraft.remove(it, key) }
    fun undo(key: String) = edit { RelayDraft.undo(it, key) }
    fun add(url: String, jobs: Set<Job>) = edit { RelayDraft.add(it, url, jobs) }
    fun setOwnJob(url: String, job: Job, on: Boolean) = edit { RelayDraft.setJob(it, url, job, on) }

    fun resetSearch() = edit {
        RelayDraft.resetSearch(it, com.nostrvault.data.model.DEFAULT_SEARCH_RELAYS, pinned(configStore.config.value))
    }

    fun plan(): RelayDraft.Plan? {
        val state = _draft.value ?: return null
        val cfg = configStore.config.value
        return RelayDraft.plan(state, cfg.macRelayWssURL, cfg.ownHavenDMInboxURL)
    }

    /** The one place the relay lists are written and published. */
    fun save() {
        val state = _draft.value ?: return
        val plan = plan() ?: return
        configStore.update { cfg ->
            RelayMatrix.applying(state.draft, cfg).let {
                if (plan.dmRelays != null) it.copy(dmRelaysUpdatedAt = System.currentTimeMillis() / 1000) else it
            }
        }
        _notPublished.value = emptyList()
        val p = state.published
        val notPublished = { name: String -> { ok: Boolean -> if (!ok) _notPublished.update { it + name } } }
        // Save edits the newest copy, fetched now; the published copy the screen opened with is what it changed.
        plan.relayListTags?.let {
            nostrService.publishOwnerRelayListTags(
                it, before = PublicRelayList.tags(emptyList(), p.read, p.write) + p.kept, openedAt = p.relayListAt,
                onDone = notPublished("Relay list"),
            )
        }
        plan.dmRelays?.let { nostrService.publishDMRelayList(it, before = p.dms, openedAt = p.dmListAt, onDone = notPublished("DM inbox")) }
        _draft.value = RelayDraft.saved(state, plan)
    }

    // ── Probe ────────────────────────────────────────────────────


    fun probe(urls: List<String>) {
        for (url in urls) {
            val key = RelayMatrix.key(url)
            if (_results.value[key] == RelayProbeResult.Probing) continue
            _results.value = _results.value + (key to RelayProbeResult.Probing)
            viewModelScope.launch {
                // One retry before calling a relay down.
                var result = measure(url)
                if (result == RelayProbeResult.Unreachable) {
                    delay(1_500)
                    result = measure(url)
                }
                _results.value = _results.value + (key to result)
            }
        }
    }

    private suspend fun measure(url: String): RelayProbeResult = withContext(Dispatchers.IO) {
        val answered = CompletableDeferred<Long>()
        val start = System.nanoTime()
        val socket = try {
            WebSocketClient.sharedClient.newWebSocket(
                Request.Builder().url(url).build(),
                object : WebSocketListener() {
                    override fun onOpen(webSocket: WebSocket, response: Response) {
                        webSocket.send("""["REQ","nv-probe",{"kinds":[0],"limit":1}]""")
                    }
                    override fun onMessage(webSocket: WebSocket, text: String) {
                        answered.complete(System.nanoTime())
                    }
                    override fun onFailure(webSocket: WebSocket, t: Throwable, response: Response?) {
                        answered.completeExceptionally(t)
                    }
                },
            )
        } catch (e: Exception) {
            return@withContext RelayProbeResult.Unreachable
        }
        val end = try {
            withTimeoutOrNull(6_000) { answered.await() }
        } catch (e: Exception) {
            null
        }
        socket.cancel()
        if (end == null) RelayProbeResult.Unreachable
        else RelayProbeResult.Answered(((end - start) / 1_000_000).toInt())
    }

    override fun onCleared() {
        blockedJob?.cancel()
        publishBlocked()
        super.onCleared()
    }
}

/** Five job columns fit a 360 dp phone with the name still readable. */
private val ColumnWidth = 36.dp
private val DotSize = 22.dp
private val RemoveWidth = 36.dp
internal val SlowAmber = ZapOrange

private fun healthColor(result: RelayProbeResult?): Color = when (result) {
    is RelayProbeResult.Answered -> if (result.milliseconds > RelayProbeResult.SLOW_MS) SlowAmber else SuccessGreen
    RelayProbeResult.Unreachable -> ErrorRed
    else -> TertiaryText
}

@OptIn(ExperimentalMaterial3Api::class)
@Composable
fun RelayMatrixScreen(
    onBack: () -> Unit,
    onOpenMediaServers: () -> Unit,
    /** After Save; true when it published a relay list (kind 10002). */
    onSaved: (publishedRelayList: Boolean) -> Unit = {},
    viewModel: RelayMatrixViewModel = hiltViewModel(),
) {
    val cfg by viewModel.config.collectAsState()
    val results by viewModel.results.collectAsState()
    val state by viewModel.draft.collectAsState()
    val colors = LocalNostrVaultColors.current
    val accent = colors.primary

    val lists = state?.draft ?: RelayMatrix.lists(cfg)
    val ownRelay = viewModel.ownRelay(cfg)
    val rows = state?.let(RelayDraft::rows).orEmpty()
    val liveRows = rows.filterNot { it.removed }
    // Only the owner's relays: the probe also times suggestions.
    val yours = (listOf(ownRelay) + liveRows.map { it.entry.url }).filter { it.isNotEmpty() }.map(RelayMatrix::key).toSet()
    val unreachable = results.filterValues { it == RelayProbeResult.Unreachable }.keys.filter { it in yours }.sorted()
    val problems = RelayMatrix.problems(lists, cfg.ownHavenDMInboxURL, unreachable)
    val follow by viewModel.follow.collectAsState()
    val refusedCertificates by LocalTls.refused.collectAsState()
    val fixCount = problems.size + refusedCertificates.size
    val changes = state?.let(RelayDraft::changeCount) ?: 0
    val notPublished by viewModel.notPublished.collectAsState()

    var selectedKey by remember { mutableStateOf<String?>(null) }
    var showingAdd by remember { mutableStateOf(false) }
    var newRelay by remember { mutableStateOf("") }
    var recommended by remember { mutableStateOf(false) }
    var confirming by remember { mutableStateOf(false) }
    var leaving by remember { mutableStateOf(false) }

    // Leaving with unsaved changes asks first: nothing is kept without Save.
    BackHandler(enabled = changes > 0) { leaving = true }
    val back = { if (changes > 0) leaving = true else onBack() }

    LaunchedEffect(ownRelay) {
        if (ownRelay.isNotEmpty()) viewModel.probe(listOf(ownRelay))
    }
    LaunchedEffect(recommended) {
        if (!recommended) return@LaunchedEffect
        viewModel.refreshSuggestions()
        viewModel.probe(RelayMatrix.wellKnownRelays.filterNot { RelayBlocklist.isBlocked(it) } +
            viewModel.follow.value.suggestions.map { it.url })
    }
    val taken = (liveRows.map { it.entry.key } + cfg.blockedRelays.map(RelayMatrix::key)).toSet()
    // Not added since the page opened, and not down.
    val followSuggestions = follow.suggestions.filter {
        RelayMatrix.key(it.url) !in taken && results[RelayMatrix.key(it.url)] != RelayProbeResult.Unreachable
    }
    // A relay already suggested above isn't repeated.
    val fastest = RelayMatrix.fastest(
        RelayMatrix.wellKnownRelays,
        results.mapNotNull { (k, r) -> (r as? RelayProbeResult.Answered)?.let { k to it.milliseconds } }.toMap(),
        lists, cfg.blockedRelays, viewModel.pinned(cfg) + followSuggestions.map { it.url },
    )

    Scaffold(
        topBar = {
            TopAppBar(
                title = { Text("Relays", fontWeight = FontWeight.Bold) },
                navigationIcon = {
                    IconButton(onClick = back) { Icon(NostrVaultIcons.Back, contentDescription = "Back") }
                },
                actions = {
                    IconButton(onClick = { newRelay = ""; showingAdd = true }, enabled = state != null) {
                        Icon(NostrVaultIcons.Create, contentDescription = "Add relay", tint = accent)
                    }
                },
                colors = TopAppBarDefaults.topAppBarColors(
                    containerColor = WindowBackground,
                    titleContentColor = PrimaryText,
                    navigationIconContentColor = PrimaryText,
                ),
            )
        },
        bottomBar = {
            if (state != null) RelaySaveBar(changes, accent) { confirming = true }
        },
        containerColor = WindowBackground,
    ) { padding ->
        LazyColumn(modifier = Modifier.fillMaxSize().padding(padding)) {
            item {
                TabRow(
                    selectedTabIndex = if (recommended) 1 else 0,
                    containerColor = WindowBackground,
                    contentColor = accent,
                ) {
                    Tab(selected = !recommended, onClick = { recommended = false }, text = { Text("Your Relays") })
                    Tab(selected = recommended, onClick = { recommended = true }, text = { Text("Recommended") })
                }
            }

            // Summary chips
            item {
                val times = results.filterKeys { it in yours }.values
                    .filterIsInstance<RelayProbeResult.Answered>().map { it.milliseconds }
                Row(
                    horizontalArrangement = Arrangement.spacedBy(8.dp),
                    modifier = Modifier.padding(horizontal = 16.dp, vertical = 8.dp),
                ) {
                    Chip("${liveRows.size + if (ownRelay.isEmpty()) 0 else 1} relays", SecondaryText)
                    if (times.isNotEmpty()) Chip("avg ${times.sum() / times.size} ms", SecondaryText)
                    if (fixCount > 0) {
                        Box(Modifier.clickable { recommended = true }) { Chip("⚠ $fixCount to fix", SlowAmber) }
                    }
                }
            }

            if (notPublished.isNotEmpty()) item { RelayNotPublishedBanner(notPublished) }

            if (recommended) {
                if (fixCount > 0) item { SectionHeader("Fixes") }
                items(refusedCertificates, key = { "cert$it" }) { hostPort ->
                    Row(
                        verticalAlignment = Alignment.CenterVertically,
                        modifier = Modifier.fillMaxWidth().padding(horizontal = 16.dp, vertical = 8.dp),
                    ) {
                        Text("!", color = ErrorRed, fontWeight = FontWeight.Bold, fontSize = 18.sp, modifier = Modifier.width(20.dp))
                        Column(Modifier.weight(1f)) {
                            Text("$hostPort changed its certificate", color = PrimaryText, fontSize = 15.sp)
                            Text("The app won't connect until you trust the new one. Do that only if you reset or reinstalled that relay.",
                                color = SecondaryText, fontSize = 12.sp)
                        }
                        Button(
                            onClick = { LocalTls.forget(hostPort) },
                            colors = ButtonDefaults.buttonColors(containerColor = accent),
                        ) { Text("Trust New") }
                    }
                }
                if (problems.isNotEmpty()) {
                    items(problems) { problem ->
                        Row(
                            verticalAlignment = Alignment.CenterVertically,
                            modifier = Modifier.fillMaxWidth().padding(horizontal = 16.dp, vertical = 8.dp),
                        ) {
                            Text("!", color = if (problem.broken) ErrorRed else SlowAmber, fontWeight = FontWeight.Bold,
                                fontSize = 18.sp, modifier = Modifier.width(20.dp))
                            Column(Modifier.weight(1f)) {
                                Text(problem.title, color = PrimaryText, fontSize = 15.sp)
                                Text(problem.detail, color = SecondaryText, fontSize = 12.sp)
                            }
                            val row = (problem as? RelayMatrix.Problem.Unreachable)?.let { p -> liveRows.firstOrNull { it.entry.key == p.key } }
                            if (row != null) {
                                Button(
                                    onClick = { viewModel.remove(row.entry.key) },
                                    colors = ButtonDefaults.buttonColors(containerColor = accent),
                                ) { Text("Remove") }
                            } else if (problem == RelayMatrix.Problem.NoSearch) {
                                Button(
                                    onClick = viewModel::resetSearch,
                                    colors = ButtonDefaults.buttonColors(containerColor = accent),
                                ) { Text("Defaults") }
                            }
                        }
                    }
                }


                item { SectionHeader("Your Follows Write To") }
                if (followSuggestions.isEmpty()) {
                    item {
                        Text(
                            if (follow.withLists == 0) "None of your follows' relay lists have loaded yet. They load as you browse profiles and your feed."
                            else "You already read from the relays your follows use most.",
                            color = SecondaryText, fontSize = 13.sp, modifier = Modifier.padding(horizontal = 16.dp, vertical = 8.dp),
                        )
                    }
                }
                items(followSuggestions, key = { "f" + it.url }) { suggestion ->
                    SuggestionRow(suggestion.url, results[RelayMatrix.key(suggestion.url)],
                        "${suggestion.follows} follows write here", accent) {
                        viewModel.add(suggestion.url, setOf(Job.READ))
                    }
                }
                item {
                    Text(
                        "Add one to Read to see more of their posts. Based on ${follow.withLists} of your ${follow.follows} follows' relay lists.",
                        color = SecondaryText, fontSize = 12.sp, modifier = Modifier.padding(horizontal = 16.dp, vertical = 8.dp),
                    )
                }

                item { SectionHeader("Fastest From This Device") }
                if (fastest.isEmpty()) {
                    item {
                        val measuring = RelayMatrix.wellKnownRelays.any { results[RelayMatrix.key(it)] == RelayProbeResult.Probing }
                        Text(if (measuring) "Measuring…" else "Nothing faster to suggest.", color = SecondaryText, fontSize = 13.sp,
                            modifier = Modifier.padding(horizontal = 16.dp, vertical = 8.dp))
                    }
                }
                items(fastest, key = { "s$it" }) { url ->
                    SuggestionRow(url, results[RelayMatrix.key(url)], null, accent) {
                        viewModel.add(url, setOf(Job.READ, Job.WRITE))
                    }
                }
                item {
                    Text(
                        "Well-known public relays, timed from here just now. Add puts it in Yours with Read and Write; Save publishes it.",
                        color = SecondaryText, fontSize = 12.sp,
                        modifier = Modifier.padding(start = 16.dp, end = 16.dp, top = 8.dp, bottom = 32.dp),
                    )
                }
            } else if (state == null) {
                item {
                    Text("Loading your relay lists…", color = SecondaryText, fontSize = 13.sp,
                        modifier = Modifier.padding(16.dp))
                }
            } else {
                val published = state!!.published
                if (!published.relayListKnown || !published.dmListKnown) {
                    item {
                        Text(
                            "Your relays didn't send your current " +
                                listOfNotNull(
                                    "relay list".takeIf { !published.relayListKnown },
                                    "DM inbox".takeIf { !published.dmListKnown },
                                ).joinToString(" or ") +
                                ". Yours shows the last copy this phone saw, and Save keeps those changes on this device.",
                            color = SlowAmber, fontSize = 12.sp,
                            modifier = Modifier.padding(horizontal = 16.dp, vertical = 8.dp),
                        )
                    }
                }

                item { SectionHeader("Yours", "Your published relay list and DM inbox, and relays you add") }
                item { ColumnHeader() }
                if (ownRelay.isNotEmpty()) {
                    item {
                        OwnRelayRow(ownRelay, results[RelayMatrix.key(ownRelay)], accent) {
                            LockedDot(true, accent)
                            LockedDot(true, accent)
                            LockedDot(cfg.ownHavenDMInboxURL.isNotEmpty(), accent)
                            val searching = lists.search.any { RelayMatrix.key(it) == RelayMatrix.key(ownRelay) }
                            JobDot(searching, accent, "${Job.SEARCH.title}, ${RelayMatrix.label(ownRelay)}") {
                                viewModel.setOwnJob(ownRelay, Job.SEARCH, !searching)
                            }
                            LockedDot(true, accent)
                        }
                    }
                }
                val mine = rows.filter { it.entry.section == RelayDraft.Section.YOURS }
                items(mine, key = { it.entry.key }) { row ->
                    MatrixRow(row, results[row.entry.key], accent, viewModel, onName = { selectedKey = row.entry.key })
                }
                if (mine.isEmpty()) {
                    item {
                        Text(
                            if (published.relayListKnown) "No published relay list yet. Tap + to add a relay, then Save." else "Nothing loaded yet.",
                            color = SecondaryText, fontSize = 13.sp, modifier = Modifier.padding(horizontal = 16.dp, vertical = 8.dp),
                        )
                    }
                }

                val defaults = rows.filter { it.entry.section == RelayDraft.Section.DEFAULTS }
                item { SectionHeader("App defaults", "Added by Nostr Vault. Used on this device only, never published.") }
                if (defaults.isNotEmpty()) item { ColumnHeader() }
                items(defaults, key = { it.entry.key }) { row ->
                    MatrixRow(row, results[row.entry.key], accent, viewModel, onName = { selectedKey = row.entry.key })
                }
                if (defaults.isEmpty()) {
                    item {
                        Text("None.", color = SecondaryText, fontSize = 13.sp,
                            modifier = Modifier.padding(horizontal = 16.dp, vertical = 8.dp))
                    }
                }
                item {
                    Text(
                        "Save publishes Read and Write (your relay list, 10002) and DMs (your DM inbox, 10050) from Yours. " +
                            "App defaults, Search and Import stay on this device. Tap a relay's name for details.",
                        color = SecondaryText, fontSize = 12.sp,
                        modifier = Modifier.padding(horizontal = 16.dp, vertical = 8.dp),
                    )
                }

                if (cfg.blockedRelays.isNotEmpty()) {
                    item { SectionHeader("Never Connect") }
                    items(cfg.blockedRelays, key = { "b$it" }) { url ->
                        Row(
                            verticalAlignment = Alignment.CenterVertically,
                            modifier = Modifier.fillMaxWidth().padding(horizontal = 16.dp, vertical = 4.dp),
                        ) {
                            Text("⊘", color = ErrorRed, fontSize = 16.sp, modifier = Modifier.width(24.dp))
                            Text(RelayMatrix.label(url), color = PrimaryText, fontSize = 15.sp, maxLines = 1,
                                overflow = TextOverflow.Ellipsis, modifier = Modifier.weight(1f))
                            TextButton(onClick = { viewModel.unblock(url) }) { Text("Unblock", color = accent) }
                        }
                    }
                    item {
                        Text(
                            "The app won't open a connection to these, even when someone you follow uses them. " +
                                "Published as your blocked relay list (10006).",
                            color = SecondaryText, fontSize = 12.sp,
                            modifier = Modifier.padding(horizontal = 16.dp, vertical = 8.dp),
                        )
                    }
                }

                // Media servers
                item { SectionHeader("Media Servers") }
                items(cfg.activeBlossomMirrors) { mirror ->
                    Text(mirror.removePrefix("https://").removePrefix("http://"), color = PrimaryText, fontSize = 15.sp,
                        maxLines = 1, overflow = TextOverflow.Ellipsis,
                        modifier = Modifier.padding(horizontal = 16.dp, vertical = 8.dp))
                }
                item {
                    Text(
                        if (cfg.activeBlossomMirrors.isEmpty()) "Add a media server" else "Edit media servers",
                        color = accent, fontSize = 15.sp,
                        modifier = Modifier.fillMaxWidth().clickable(onClick = onOpenMediaServers)
                            .padding(horizontal = 16.dp, vertical = 12.dp),
                    )
                    Text(
                        "Where your photos and videos are stored. These aren't relays.",
                        color = SecondaryText, fontSize = 12.sp,
                        modifier = Modifier.padding(start = 16.dp, end = 16.dp, bottom = 32.dp),
                    )
                }
            }
        }
    }

    if (showingAdd) {
        val parsed = RelayMatrix.relayURL(newRelay)
        AlertDialog(
            onDismissRequest = { showingAdd = false },
            title = { Text("Add Relay") },
            text = {
                Column {
                    OutlinedTextField(value = newRelay, onValueChange = { newRelay = it },
                        placeholder = { Text("relay.example.com") }, singleLine = true)
                    Spacer(Modifier.height(8.dp))
                    Text("It goes in Yours with Read and Write. Save publishes it.", color = SecondaryText, fontSize = 12.sp)
                }
            },
            confirmButton = {
                TextButton(enabled = parsed != null, onClick = {
                    parsed?.let { viewModel.add(it, setOf(Job.READ, Job.WRITE)) }
                    showingAdd = false
                }) { Text("Add") }
            },
            dismissButton = { TextButton(onClick = { showingAdd = false }) { Text("Cancel") } },
        )
    }

    val selected = selectedKey?.let { key -> liveRows.firstOrNull { it.entry.key == key } }
    if (selected != null) {
        ModalBottomSheet(onDismissRequest = { selectedKey = null }, containerColor = Surface2) {
            RelayDetail(
                row = RelayMatrix.Row(selected.entry.url, selected.jobs),
                result = results[selected.entry.key],
                accent = accent,
                onSet = { job, on -> if (selected.has(job) != on) viewModel.toggle(selected.entry.key, job) },
                onBlock = {
                    viewModel.block(selected.entry.url)
                    selectedKey = null
                },
                onRemove = {
                    viewModel.remove(selected.entry.key)
                    selectedKey = null
                },
                onDone = { selectedKey = null },
            )
        }
    }

    val plan = if (confirming) viewModel.plan() else null
    if (plan != null) {
        RelaySaveSheet(
            plan = plan,
            changes = changes,
            accent = accent,
            onSave = {
                viewModel.save()
                confirming = false
                onSaved(plan.relayListTags != null)
            },
            onDismiss = { confirming = false },
        )
    }

    if (leaving) {
        AlertDialog(
            onDismissRequest = { leaving = false },
            title = { Text("Discard ${changes.changesLabel()}?") },
            text = { Text("Nothing has been saved or published.") },
            confirmButton = {
                TextButton(onClick = { leaving = false; onBack() }) { Text("Discard", color = ErrorRed) }
            },
            dismissButton = { TextButton(onClick = { leaving = false }) { Text("Keep editing") } },
        )
    }
}

@Composable
private fun ColumnHeader() {
    Row(
        verticalAlignment = Alignment.CenterVertically,
        modifier = Modifier.fillMaxWidth().padding(start = 16.dp + RemoveWidth - 12.dp, end = 12.dp, top = 8.dp, bottom = 2.dp),
    ) {
        Text("Relay", color = SecondaryText, fontSize = 12.sp, fontWeight = FontWeight.SemiBold, modifier = Modifier.weight(1f))
        Job.entries.forEach {
            // "SEARCH" and "IMPORT" are a hair wider than their columns; let
            // them spill evenly into the gaps rather than wrap or clip.
            Box(Modifier.width(ColumnWidth), contentAlignment = Alignment.Center) {
                Text(it.title.uppercase(), color = SecondaryText, fontSize = 9.sp,
                    fontWeight = FontWeight.SemiBold, maxLines = 1, softWrap = false,
                    modifier = Modifier.wrapContentWidth(unbounded = true))
            }
        }
    }
}

/** One relay: Remove (or Undo), its health and name, and a dot per job. Never moves while edited. */
@Composable
private fun MatrixRow(
    row: RelayDraft.Row,
    result: RelayProbeResult?,
    accent: Color,
    viewModel: RelayMatrixViewModel,
    onName: () -> Unit,
) {
    val name = RelayMatrix.label(row.entry.url)
    Row(
        verticalAlignment = Alignment.CenterVertically,
        modifier = Modifier.fillMaxWidth().padding(start = 4.dp, end = 12.dp),
    ) {
        if (row.removed) {
            Box(
                contentAlignment = Alignment.Center,
                modifier = Modifier.size(RemoveWidth).clickable { viewModel.undo(row.entry.key) }
                    .semantics { contentDescription = "Undo remove $name" },
            ) { Text("↺", color = accent, fontSize = 18.sp) }
        } else {
            Box(
                contentAlignment = Alignment.Center,
                modifier = Modifier.size(RemoveWidth).clickable { viewModel.remove(row.entry.key) }
                    .semantics { contentDescription = "Remove $name" },
            ) {
                Box(contentAlignment = Alignment.Center, modifier = Modifier.size(22.dp).background(ErrorRed, CircleShape)) {
                    Box(Modifier.width(10.dp).height(2.dp).background(Color.White))
                }
            }
        }
        Box(Modifier.size(8.dp).background(if (row.removed) TertiaryText else healthColor(result), CircleShape))
        Spacer(Modifier.width(8.dp))
        Column(
            modifier = Modifier.weight(1f).then(if (row.removed) Modifier else Modifier.clickable(onClick = onName)),
        ) {
            Text(
                name, color = if (row.removed) TertiaryText else PrimaryText, fontSize = 15.sp, maxLines = 1,
                overflow = TextOverflow.Ellipsis,
                textDecoration = if (row.removed) TextDecoration.LineThrough else null,
            )
            Row(verticalAlignment = Alignment.CenterVertically) {
                if (row.removed) {
                    Text("Removed", color = ErrorRed, fontSize = 12.sp)
                } else {
                    val (text, tint) = subtitle(result, emptyList())
                    Text(text, color = tint, fontSize = 12.sp, maxLines = 1, overflow = TextOverflow.Ellipsis)
                }
                Spacer(Modifier.width(6.dp))
                if (row.entry.section == RelayDraft.Section.YOURS) Badge("YOURS", accent) else Badge("DEFAULT", SecondaryText)
            }
        }
        Job.entries.forEach { job ->
            if (row.removed) {
                DimDot(job in row.jobs)
            } else {
                JobDot(row.has(job), accent, "${job.title}, $name") { viewModel.toggle(row.entry.key, job) }
            }
        }
    }
}

/** The vault's own relay: always Read, Write, DMs and Import; only Search can change. */
@Composable
private fun OwnRelayRow(url: String, result: RelayProbeResult?, accent: Color, dots: @Composable RowScope.() -> Unit) {
    Row(
        verticalAlignment = Alignment.CenterVertically,
        modifier = Modifier.fillMaxWidth().padding(start = 4.dp, end = 12.dp, top = 2.dp, bottom = 2.dp),
    ) {
        Spacer(Modifier.width(RemoveWidth))
        Box(Modifier.size(8.dp).background(healthColor(result), CircleShape))
        Spacer(Modifier.width(8.dp))
        Column(Modifier.weight(1f)) {
            Text(RelayMatrix.label(url), color = PrimaryText, fontSize = 15.sp, maxLines = 1, overflow = TextOverflow.Ellipsis)
            Row(verticalAlignment = Alignment.CenterVertically) {
                val (text, tint) = subtitle(result, emptyList())
                Text(text, color = tint, fontSize = 12.sp, maxLines = 1)
                Spacer(Modifier.width(6.dp))
                Badge("YOUR RELAY", accent)
            }
        }
        dots()
    }
}

@Composable
private fun Badge(text: String, tint: Color) {
    Text(
        text, color = tint, fontSize = 9.sp, fontWeight = FontWeight.Bold, maxLines = 1, softWrap = false,
        modifier = Modifier.background(tint.copy(alpha = 0.15f), RoundedCornerShape(3.dp)).padding(horizontal = 5.dp, vertical = 1.dp),
    )
}

@Composable
private fun DimDot(on: Boolean) {
    Box(contentAlignment = Alignment.Center, modifier = Modifier.width(ColumnWidth).height(44.dp)) {
        Box(
            Modifier.size(DotSize)
                .background(if (on) TertiaryText.copy(alpha = 0.4f) else Color.Transparent, CircleShape)
                .border(1.5.dp, TertiaryText.copy(alpha = 0.4f), CircleShape),
        )
    }
}

@Composable
private fun SectionHeader(title: String, detail: String? = null) {
    Column(Modifier.padding(start = 16.dp, end = 16.dp, top = 20.dp, bottom = 4.dp)) {
        Text(title.uppercase(), color = SecondaryText, fontSize = 12.sp, fontWeight = FontWeight.SemiBold, letterSpacing = 1.sp)
        if (detail != null) Text(detail, color = TertiaryText, fontSize = 12.sp)
    }
}

@Composable
private fun Chip(text: String, tint: Color) {
    Text(text, color = tint, fontSize = 12.sp,
        modifier = Modifier.background(tint.copy(alpha = 0.12f), RoundedCornerShape(50))
            .padding(horizontal = 10.dp, vertical = 5.dp))
}

private fun subtitle(result: RelayProbeResult?, tags: List<String>): Pair<String, Color> {
    val parts = mutableListOf<String>()
    var tint = SecondaryText
    when (result) {
        is RelayProbeResult.Answered -> {
            parts += "${result.milliseconds} ms"
            if (result.milliseconds > RelayProbeResult.SLOW_MS) { parts += "slow"; tint = SlowAmber }
        }
        RelayProbeResult.Unreachable -> { parts += "not answering"; tint = ErrorRed }
        else -> parts += "…"
    }
    return (parts + tags).joinToString(" · ") to tint
}

@Composable
private fun JobDot(on: Boolean, accent: Color, label: String, onClick: () -> Unit) {
    Box(
        contentAlignment = Alignment.Center,
        modifier = Modifier.width(ColumnWidth).height(44.dp).clickable(onClick = onClick)
            .semantics { contentDescription = label; stateDescription = if (on) "On" else "Off" },
    ) {
        Box(
            Modifier.size(DotSize)
                .background(if (on) accent else Color.Transparent, CircleShape)
                .border(1.5.dp, if (on) accent else TertiaryText, CircleShape),
        )
    }
}

@Composable
private fun LockedDot(on: Boolean, accent: Color) {
    Box(contentAlignment = Alignment.Center, modifier = Modifier.width(ColumnWidth).height(44.dp)) {
        Box(
            contentAlignment = Alignment.Center,
            modifier = Modifier.size(DotSize)
                .background(if (on) accent else Color.Transparent, CircleShape)
                .border(1.5.dp, if (on) accent else TertiaryText, CircleShape),
        ) {
            if (on) Icon(NostrVaultIcons.Lock, contentDescription = null, tint = Color.White, modifier = Modifier.size(11.dp))
        }
    }
}

@Composable
private fun RelayDetail(
    row: RelayMatrix.Row,
    result: RelayProbeResult?,
    accent: Color,
    onSet: (Job, Boolean) -> Unit,
    onBlock: () -> Unit,
    onRemove: () -> Unit,
    onDone: () -> Unit,
) {
    Column(Modifier.fillMaxWidth().padding(horizontal = 20.dp).padding(bottom = 32.dp)) {
        // iOS: the relay's name as an inline title, Done, then its speed row.
        Row(verticalAlignment = Alignment.CenterVertically) {
            Text(RelayMatrix.label(row.url), color = PrimaryText, fontSize = 17.sp, fontWeight = FontWeight.SemiBold, modifier = Modifier.weight(1f))
            TextButton(onClick = onDone) { Text("Done", color = accent, fontSize = 17.sp, fontWeight = FontWeight.SemiBold) }
        }
        Row(verticalAlignment = Alignment.CenterVertically, modifier = Modifier.padding(top = 4.dp, bottom = 8.dp)) {
            Box(Modifier.size(10.dp).background(healthColor(result), CircleShape))
            Text(row.url, color = SecondaryText, fontSize = 12.sp, modifier = Modifier.padding(start = 8.dp))
        }
        when (result) {
            is RelayProbeResult.Answered -> "${result.milliseconds} ms"
            RelayProbeResult.Unreachable -> "Not answering"
            else -> null
        }?.let { speed ->
            Row(Modifier.padding(bottom = 12.dp)) {
                Text("Speed from this device", color = PrimaryText, fontSize = 15.sp, modifier = Modifier.weight(1f))
                Text(speed, color = SecondaryText, fontSize = 15.sp)
            }
        }
        Job.entries.forEach { JobSwitch(it, row.has(it), accent, onSet) }
        if (RelayMatrix.isPublicRelay(DMInbox.normalizedRelayURL(row.url))) {
            Column(Modifier.fillMaxWidth().clickable(onClick = onBlock).padding(vertical = 8.dp)) {
                Text("Never Connect", color = ErrorRed, fontSize = 15.sp)
                Text("Remove it and block it everywhere in the app", color = SecondaryText, fontSize = 12.sp)
            }
        }
        Text("Write without Read sends your posts here but never loads from it. Changes wait for Save.",
            color = SecondaryText, fontSize = 12.sp, modifier = Modifier.padding(top = 4.dp))
        Row(Modifier.padding(top = 16.dp)) {
            Text("Used by", color = SecondaryText, fontSize = 14.sp, modifier = Modifier.weight(1f))
            Text(usedBy(row.jobs), color = PrimaryText, fontSize = 14.sp)
        }
        TextButton(onClick = onRemove, modifier = Modifier.fillMaxWidth().padding(top = 12.dp)) {
            Text("Remove Relay", color = ErrorRed, fontSize = 16.sp)
        }
    }
}

@Composable
private fun JobSwitch(job: Job, on: Boolean, accent: Color, onSet: (Job, Boolean) -> Unit) {
    Row(verticalAlignment = Alignment.CenterVertically, modifier = Modifier.fillMaxWidth().padding(vertical = 6.dp)) {
        Column(Modifier.weight(1f)) {
            Text(job.title, color = PrimaryText, fontSize = 15.sp)
            Text(job.detail, color = SecondaryText, fontSize = 12.sp)
        }
        Switch(
            checked = on,
            onCheckedChange = { onSet(job, it) },
            colors = SwitchDefaults.colors(checkedThumbColor = PrimaryText, checkedTrackColor = accent),
        )
    }
}

private fun usedBy(jobs: Set<Job>): String = buildList {
    if (Job.READ in jobs) addAll(listOf("Feed", "Profiles", "Threads", "Zaps", "Polls", "Live", "Reels"))
    if (Job.WRITE in jobs) addAll(listOf("Your posts", "Reactions"))
    if (Job.DMS in jobs) add("DMs")
    if (Job.SEARCH in jobs) add("Search")
    if (Job.IMPORT in jobs) add("Import")
}.ifEmpty { listOf("Nothing") }.joinToString(", ")

@Composable
private fun SuggestionRow(url: String, result: RelayProbeResult?, detail: String?, accent: Color, onAdd: () -> Unit) {
    Row(
        verticalAlignment = Alignment.CenterVertically,
        modifier = Modifier.fillMaxWidth().padding(horizontal = 16.dp, vertical = 6.dp),
    ) {
        Box(Modifier.size(8.dp).background(healthColor(result), CircleShape))
        Spacer(Modifier.width(10.dp))
        Column(Modifier.weight(1f)) {
            Text(RelayMatrix.label(url), color = PrimaryText, fontSize = 15.sp, maxLines = 1, overflow = TextOverflow.Ellipsis)
            val (text, tint) = subtitle(result, listOfNotNull(detail))
            Text(text, color = tint, fontSize = 12.sp, maxLines = 1, overflow = TextOverflow.Ellipsis)
        }
        Button(
            onClick = onAdd,
            colors = ButtonDefaults.buttonColors(containerColor = accent),
            modifier = Modifier.semantics { contentDescription = "Add ${RelayMatrix.label(url)}" },
        ) { Text("Add") }
    }
}
