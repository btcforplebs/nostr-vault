package com.nostrvault.ui.screens.settings

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
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import androidx.hilt.navigation.compose.hiltViewModel
import androidx.lifecycle.ViewModel
import androidx.lifecycle.viewModelScope
import com.nostrvault.data.local.ConfigStore
import com.nostrvault.data.remote.LocalTls
import com.nostrvault.data.remote.WebSocketClient
import com.nostrvault.relay.DMInbox
import com.nostrvault.relay.HavenConfig
import com.nostrvault.relay.RelayBlocklist
import com.nostrvault.relay.RelayMatrix
import com.nostrvault.relay.RelayMatrix.Job
import com.nostrvault.service.FeedService
import com.nostrvault.service.NostrService
import com.nostrvault.ui.theme.*
import dagger.hilt.android.lifecycle.HiltViewModel
import kotlinx.coroutines.CompletableDeferred
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.Job as CoroutineJob
import kotlinx.coroutines.delay
import kotlinx.coroutines.flow.MutableStateFlow
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
 * Settings > Relays: every relay the owner uses on one screen. Port of iOS
 * RelayMatrixView. Edits go straight to the config; a DM change republishes
 * kind 10050 and a Read/Write change republishes kind 10002 (when the owner
 * publishes it), each once edits settle. The Recommended page suggests relays
 * the follows write to and the fastest well-known relays; Never connect
 * blocks a relay and publishes kind 10006.
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

    private var dmJob: CoroutineJob? = null
    private var dmPending = false
    private var relayListJob: CoroutineJob? = null
    private var relayListPending = false
    private var blockedJob: CoroutineJob? = null
    private var blockedPending = false

    data class FollowInfo(
        val suggestions: List<RelayMatrix.FollowSuggestion> = emptyList(),
        val withLists: Int = 0,
        val follows: Int = 0,
    )

    private val _follow = MutableStateFlow(FollowInfo())
    val follow = _follow.asStateFlow()

    /** Walks every follow's relay list, so it runs when asked, not per frame. */
    fun refreshSuggestions() {
        val cfg = configStore.config.value
        val follows = feedService.followedPubkeys.value
        val outbox = nostrService.outboxRelays.value
        _follow.value = FollowInfo(
            suggestions = RelayMatrix.followSuggestions(
                follows, outbox, RelayMatrix.lists(cfg), cfg.blockedRelays, pinned(cfg)),
            withLists = RelayMatrix.followsWithRelayLists(follows, outbox),
            follows = follows.size,
        )
    }

    fun block(url: String) {
        val cfg = configStore.config.value
        val (lists, blocked) = RelayMatrix.blocking(url, RelayMatrix.lists(cfg), cfg.blockedRelays)
        apply(lists)
        setBlocked(blocked)
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

    fun apply(new: RelayMatrix.Lists) {
        val old = RelayMatrix.lists(configStore.config.value)
        if (new == old) return
        configStore.update { RelayMatrix.applying(new, it) }
        if (new.dms != old.dms) scheduleDM()
        if (new.read != old.read || new.write != old.write) scheduleRelayList()
        // Only relays with no speed yet, so the timed rows keep their dots.
        probe(RelayMatrix.needingProbe(RelayMatrix.rows(new).map { it.url }, _results.value.keys))
    }

    fun resetSearch() = configStore.update { it.copy(searchRelays = null) }

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

    // ── Publishing ───────────────────────────────────────────────

    private fun scheduleDM() {
        dmPending = true
        dmJob?.cancel()
        dmJob = viewModelScope.launch {
            delay(2_000)
            publishDM()
        }
    }

    private fun publishDM() {
        if (!dmPending) return
        dmPending = false
        nostrService.publishOwnerDMInboxList()
    }

    private fun scheduleRelayList() {
        relayListPending = true
        relayListJob?.cancel()
        relayListJob = viewModelScope.launch {
            delay(2_000)
            publishRelayList()
        }
    }

    /** Read and Write are the public relay list: republish it when the owner publishes it. */
    private fun publishRelayList() {
        if (!relayListPending) return
        relayListPending = false
        val cfg = configStore.config.value
        val owner = cfg.ownerNpub
        if (owner.isNotEmpty() && cfg.publishRelayListPerAccount[owner] == true) {
            nostrService.publishRelayList(owner)
        }
    }

    override fun onCleared() {
        // Leaving inside the debounce still publishes the edit.
        dmJob?.cancel()
        relayListJob?.cancel()
        blockedJob?.cancel()
        publishDM()
        publishRelayList()
        publishBlocked()
        super.onCleared()
    }
}

private val ColumnWidth = 42.dp
private val SlowAmber = ZapOrange

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
    viewModel: RelayMatrixViewModel = hiltViewModel(),
) {
    val cfg by viewModel.config.collectAsState()
    val results by viewModel.results.collectAsState()
    val colors = LocalNostrVaultColors.current
    val accent = colors.primary

    val lists = RelayMatrix.lists(cfg)
    val ownRelay = viewModel.ownRelay(cfg)
    val rows = RelayMatrix.rows(lists, viewModel.pinned(cfg))
    // Only the owner's relays: the probe also times suggestions.
    val yours = (listOf(ownRelay) + rows.map { it.url }).filter { it.isNotEmpty() }.map(RelayMatrix::key).toSet()
    val unreachable = results.filterValues { it == RelayProbeResult.Unreachable }.keys.filter { it in yours }.sorted()
    val problems = RelayMatrix.problems(lists, cfg.ownHavenDMInboxURL, unreachable)
    val follow by viewModel.follow.collectAsState()
    val refusedCertificates by LocalTls.refused.collectAsState()
    val fixCount = problems.size + refusedCertificates.size

    var selectedKey by remember { mutableStateOf<String?>(null) }
    var showingAdd by remember { mutableStateOf(false) }
    var newRelay by remember { mutableStateOf("") }
    var recommended by remember { mutableStateOf(false) }

    LaunchedEffect(Unit) {
        viewModel.probe((listOf(ownRelay) + rows.map { it.url }).filter { it.isNotEmpty() })
        viewModel.refreshSuggestions()
    }
    LaunchedEffect(recommended) {
        if (!recommended) return@LaunchedEffect
        viewModel.refreshSuggestions()
        viewModel.probe(RelayMatrix.wellKnownRelays.filterNot { RelayBlocklist.isBlocked(it) } +
            viewModel.follow.value.suggestions.map { it.url })
    }
    val taken = (rows.map { it.id } + cfg.blockedRelays.map(RelayMatrix::key)).toSet()
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
                    IconButton(onClick = onBack) { Icon(NostrVaultIcons.Back, contentDescription = "Back") }
                },
                actions = {
                    IconButton(onClick = { newRelay = ""; showingAdd = true }) {
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
                    Chip("${rows.size + if (ownRelay.isEmpty()) 0 else 1} relays", SecondaryText)
                    if (times.isNotEmpty()) Chip("avg ${times.sum() / times.size} ms", SecondaryText)
                    if (fixCount > 0) {
                        Box(Modifier.clickable { recommended = true }) { Chip("⚠ $fixCount to fix", SlowAmber) }
                    }
                }
            }

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
                            val row = (problem as? RelayMatrix.Problem.Unreachable)?.let { p -> rows.firstOrNull { it.id == p.key } }
                            if (row != null) {
                                Button(
                                    onClick = { viewModel.apply(RelayMatrix.removing(row.url, lists)) },
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
                        viewModel.apply(RelayMatrix.setting(Job.READ, true, suggestion.url, lists))
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
                        viewModel.apply(RelayMatrix.adding(url, lists))
                    }
                }
                item {
                    Text(
                        "Well-known public relays, timed from here just now. Add puts it in Read and Write.",
                        color = SecondaryText, fontSize = 12.sp,
                        modifier = Modifier.padding(start = 16.dp, end = 16.dp, top = 8.dp, bottom = 32.dp),
                    )
                }
            } else {
                // Grid header
                item {
                    Row(
                        verticalAlignment = Alignment.CenterVertically,
                        modifier = Modifier.fillMaxWidth().padding(start = 16.dp, end = 16.dp, top = 20.dp, bottom = 4.dp),
                    ) {
                        Text("RELAY", color = SecondaryText, fontSize = 12.sp, fontWeight = FontWeight.SemiBold,
                            modifier = Modifier.weight(1f))
                        Job.columns.forEach {
                            // "SEARCH" is a hair wider than its column; let it spill
                            // evenly into the gaps rather than wrap or clip.
                            Box(Modifier.width(ColumnWidth), contentAlignment = Alignment.Center) {
                                Text(it.title.uppercase(), color = SecondaryText, fontSize = 11.sp,
                                    fontWeight = FontWeight.SemiBold, maxLines = 1, softWrap = false,
                                    modifier = Modifier.wrapContentWidth(unbounded = true))
                            }
                        }
                    }
                }

                if (ownRelay.isNotEmpty()) {
                    item {
                        GridRow(
                            name = RelayMatrix.label(ownRelay),
                            result = results[RelayMatrix.key(ownRelay)],
                            tags = emptyList(),
                            badge = "YOUR RELAY",
                            onName = null,
                            accent = accent,
                        ) {
                            LockedDot(true, accent)
                            LockedDot(true, accent)
                            LockedDot(cfg.ownHavenDMInboxURL.isNotEmpty(), accent)
                            val searching = lists.search.any { RelayMatrix.key(it) == RelayMatrix.key(ownRelay) }
                            JobDot(searching, accent, "${Job.SEARCH.title}, ${RelayMatrix.label(ownRelay)}") {
                                viewModel.apply(RelayMatrix.setting(Job.SEARCH, !searching, ownRelay, lists))
                            }
                        }
                    }
                }
                items(rows, key = { it.id }) { row ->
                    GridRow(
                        name = RelayMatrix.label(row.url),
                        result = results[row.id],
                        tags = Job.advanced.filter(row::has).map { it.title },
                        badge = null,
                        onName = { selectedKey = row.id },
                        accent = accent,
                    ) {
                        Job.columns.forEach { job ->
                            JobDot(row.has(job), accent, "${job.title}, ${RelayMatrix.label(row.url)}") {
                                viewModel.apply(RelayMatrix.setting(job, !row.has(job), row.url, lists))
                            }
                        }
                    }
                }
                if (rows.isEmpty() && ownRelay.isEmpty()) {
                    item {
                        Text("No relays yet. Tap + to add one.", color = SecondaryText, fontSize = 13.sp,
                            modifier = Modifier.padding(16.dp))
                    }
                }
                item {
                    Text(
                        "Read + Write are your public relay list (10002). DMs are your DM inbox (10050). " +
                            "Search is where searches go. Tap a relay's name for Import.",
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
                        "Where your photos and videos are stored (Blossom). These aren't relays.",
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
                    Text("It starts with Read and Write. Tap its name to change that.", color = SecondaryText, fontSize = 12.sp)
                }
            },
            confirmButton = {
                TextButton(enabled = parsed != null, onClick = {
                    parsed?.let { viewModel.apply(RelayMatrix.adding(it, lists)) }
                    showingAdd = false
                }) { Text("Add") }
            },
            dismissButton = { TextButton(onClick = { showingAdd = false }) { Text("Cancel") } },
        )
    }

    val selected = selectedKey?.let { key -> rows.firstOrNull { it.id == key } }
    if (selected != null) {
        ModalBottomSheet(onDismissRequest = { selectedKey = null }, containerColor = Surface2) {
            RelayDetail(
                row = selected,
                result = results[selected.id],
                accent = accent,
                onSet = { job, on -> viewModel.apply(RelayMatrix.setting(job, on, selected.url, lists)) },
                onBlock = {
                    viewModel.block(selected.url)
                    selectedKey = null
                },
                onRemove = {
                    viewModel.apply(RelayMatrix.removing(selected.url, lists))
                    selectedKey = null
                },
            )
        }
    }
}

@Composable
private fun SectionHeader(title: String) {
    Text(title.uppercase(), color = SecondaryText, fontSize = 12.sp, fontWeight = FontWeight.SemiBold,
        letterSpacing = 1.sp, modifier = Modifier.padding(start = 16.dp, top = 20.dp, bottom = 4.dp))
}

@Composable
private fun Chip(text: String, tint: Color) {
    Text(text, color = tint, fontSize = 12.sp,
        modifier = Modifier.background(tint.copy(alpha = 0.12f), RoundedCornerShape(50))
            .padding(horizontal = 10.dp, vertical = 5.dp))
}

@Composable
private fun GridRow(
    name: String,
    result: RelayProbeResult?,
    tags: List<String>,
    badge: String?,
    onName: (() -> Unit)?,
    accent: Color,
    dots: @Composable RowScope.() -> Unit,
) {
    Row(
        verticalAlignment = Alignment.CenterVertically,
        modifier = Modifier.fillMaxWidth().padding(start = 16.dp, end = 16.dp, top = 6.dp, bottom = 6.dp),
    ) {
        Box(Modifier.size(8.dp).background(healthColor(result), CircleShape))
        Spacer(Modifier.width(10.dp))
        Column(
            modifier = Modifier.weight(1f)
                .then(if (onName != null) Modifier.clickable(onClick = onName) else Modifier),
        ) {
            Text(name, color = PrimaryText, fontSize = 15.sp, maxLines = 1, overflow = TextOverflow.Ellipsis)
            Row(verticalAlignment = Alignment.CenterVertically) {
                val (text, tint) = subtitle(result, tags)
                Text(text, color = tint, fontSize = 12.sp, maxLines = 1, overflow = TextOverflow.Ellipsis)
                if (badge != null) {
                    Spacer(Modifier.width(6.dp))
                    Text(badge, color = accent, fontSize = 9.sp, fontWeight = FontWeight.Bold,
                        modifier = Modifier.background(accent.copy(alpha = 0.15f), RoundedCornerShape(3.dp))
                            .padding(horizontal = 5.dp, vertical = 1.dp))
                }
            }
        }
        dots()
    }
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
            Modifier.size(24.dp)
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
            modifier = Modifier.size(24.dp)
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
) {
    Column(Modifier.fillMaxWidth().padding(horizontal = 20.dp).padding(bottom = 32.dp)) {
        Row(verticalAlignment = Alignment.CenterVertically) {
            Box(Modifier.size(10.dp).background(healthColor(result), CircleShape))
            Spacer(Modifier.width(8.dp))
            Text(RelayMatrix.label(row.url), color = PrimaryText, fontSize = 20.sp, fontWeight = FontWeight.Bold)
        }
        Text(
            row.url + when (result) {
                is RelayProbeResult.Answered -> " · ${result.milliseconds} ms from this device"
                RelayProbeResult.Unreachable -> " · not answering"
                else -> ""
            },
            color = SecondaryText, fontSize = 12.sp, modifier = Modifier.padding(top = 4.dp, bottom = 12.dp),
        )
        Job.columns.forEach { JobSwitch(it, row.has(it), accent, onSet) }
        Text("ADVANCED", color = SecondaryText, fontSize = 12.sp, fontWeight = FontWeight.SemiBold,
            modifier = Modifier.padding(top = 16.dp, bottom = 4.dp))
        Job.advanced.forEach { JobSwitch(it, row.has(it), accent, onSet) }
        if (RelayMatrix.isPublicRelay(DMInbox.normalizedRelayURL(row.url))) {
            Column(Modifier.fillMaxWidth().clickable(onClick = onBlock).padding(vertical = 8.dp)) {
                Text("Never Connect", color = ErrorRed, fontSize = 15.sp)
                Text("Remove it and block it everywhere in the app", color = SecondaryText, fontSize = 12.sp)
            }
        }
        Text("Write without Read sends your posts here but never loads from it.",
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
