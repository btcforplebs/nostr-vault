package com.nostrvault.ui.screens

import android.util.Log
import android.widget.Toast
import androidx.compose.foundation.layout.*
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.items
import androidx.compose.material3.*
import androidx.compose.runtime.*
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.semantics.stateDescription
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.style.TextAlign
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import androidx.hilt.navigation.compose.hiltViewModel
import androidx.lifecycle.SavedStateHandle
import androidx.lifecycle.ViewModel
import androidx.lifecycle.viewModelScope
import com.nostrvault.data.local.ConfigStore
import com.nostrvault.data.model.FeedNote
import com.nostrvault.data.model.FeedProfile
import com.nostrvault.data.remote.WebSocketClient
import com.nostrvault.relay.HavenBridge
import com.nostrvault.service.FeedFilterEngine
import com.nostrvault.service.FeedService
import com.nostrvault.service.NostrService
import com.nostrvault.service.ZapSendService
import com.nostrvault.ui.components.GlassPill
import com.nostrvault.ui.components.GlassScaffold
import com.nostrvault.ui.components.NoteCard
import com.nostrvault.ui.components.ZapFlight
import com.nostrvault.ui.navigation.HashtagLink
import com.nostrvault.ui.theme.*
import dagger.hilt.android.lifecycle.HiltViewModel
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.Job
import kotlinx.coroutines.delay
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.SharingStarted
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.asStateFlow
import kotlinx.coroutines.flow.combine
import kotlinx.coroutines.flow.map
import kotlinx.coroutines.flow.stateIn
import kotlinx.coroutines.launch
import kotlinx.serialization.json.Json
import kotlinx.serialization.json.JsonArray
import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.JsonPrimitive
import kotlinx.serialization.json.buildJsonArray
import kotlinx.serialization.json.buildJsonObject
import kotlinx.serialization.json.contentOrNull
import kotlinx.serialization.json.jsonArray
import kotlinx.serialization.json.jsonPrimitive
import kotlinx.serialization.json.longOrNull
import kotlinx.serialization.json.put
import kotlinx.serialization.json.putJsonArray
import javax.inject.Inject

/**
 * Posts tagged with one hashtag (`#t`), newest first, live: the subscription
 * stays open so new posts arrive while the screen is up. Two groups: the
 * people you follow, then everyone else the shield lets through (your Web of
 * Trust, or everyone). Port of iOS `HashtagFeedModel` / `HashtagFeedView`.
 */
@HiltViewModel
class HashtagFeedViewModel @Inject constructor(
    savedStateHandle: SavedStateHandle,
    private val nostrService: NostrService,
    private val configStore: ConfigStore,
    private val feedService: FeedService,
    private val zapSendService: ZapSendService,
) : ViewModel() {

    companion object {
        private const val TAG = "HashtagFeed"
        private const val LIMIT = 100
        private const val MAX_NOTES = 300
        /** Authors per REQ filter; relays reject very large filters (iOS `trustedAuthorsCap`). */
        private const val AUTHORS_CAP = 500
        /** Never spin forever if every relay is slow or down. */
        private const val LOADING_TIMEOUT_MS = 8_000L
        private const val DEFAULT_ZAP_SATS = SearchViewModel.DEFAULT_ZAP_SATS
    }

    val tag: String = HashtagLink.normalize(savedStateHandle.get<String>("tag").orEmpty()).orEmpty()

    private val json = Json { ignoreUnknownKeys = true }

    private val _fromFollows = MutableStateFlow<List<FeedNote>>(emptyList())
    val fromFollows: StateFlow<List<FeedNote>> = _fromFollows.asStateFlow()

    private val _fromOthers = MutableStateFlow<List<FeedNote>>(emptyList())
    val fromOthers: StateFlow<List<FeedNote>> = _fromOthers.asStateFlow()

    private val _isLoading = MutableStateFlow(true)
    val isLoading: StateFlow<Boolean> = _isLoading.asStateFlow()

    /** The app-wide shield: Web of Trust (false) or everyone (true). */
    val globalShowsEveryone: StateFlow<Boolean> = configStore.config
        .map { it.globalShowsEveryone }
        .stateIn(viewModelScope, SharingStarted.Eagerly, configStore.config.value.globalShowsEveryone)

    val profiles = nostrService.profiles
    val likedEventIds = feedService.likedEventIds
    val repostedEventIds = feedService.repostedEventIds
    val noteStats = feedService.noteStats
    val quotedNotesCache = feedService.quotedNotes

    private val _toast = MutableStateFlow<String?>(null)
    val toast = _toast.asStateFlow()

    private val lock = Any()
    private val seen = HashSet<String>()
    @Volatile private var follows: Set<String> = emptySet()
    private val requestedAuthors = HashSet<String>()
    @Volatile private var generation = 0
    private var clients = mutableListOf<WebSocketClient>()
    private var jobs = mutableListOf<Job>()

    init {
        // The follow list and the trust graph can arrive after the screen opens.
        viewModelScope.launch {
            combine(
                feedService.followedPubkeys,
                feedService.wotPubkeys.map { it.size },
                globalShowsEveryone,
            ) { followed, _, _ -> followed }
                .collect { start() }
        }
    }

    /** Leaving the Web of Trust goes through the screen's warning first. */
    fun setGlobalShowsEveryone(on: Boolean) {
        feedService.setGlobalShowsEveryone(on)
    }

    /**
     * (Re)opens the subscription. Your own posts count with your follows: you
     * just tagged it, you want to see it.
     */
    private fun start() {
        stop()
        val followSet = buildSet {
            addAll(feedService.followedPubkeys.value)
            configStore.activeAccountHexPubkey.value.takeIf { it.isNotEmpty() }?.let(::add)
        }
        // Null is everyone; empty is nobody (no Web of Trust yet fails closed, like Global).
        val trust = feedService.globalTrustSet()
        val gen = synchronized(lock) {
            generation += 1
            seen.clear()
            follows = followSet
            generation
        }
        _fromFollows.value = emptyList()
        _fromOthers.value = emptyList()
        _isLoading.value = true

        if (tag.isEmpty()) {
            _isLoading.value = false
            return
        }
        // Follows asked by name, so a busy tag cannot push them out of the page;
        // past the cap, the open filter finds them. Capped so the REQ stays
        // under relay message limits.
        val filters = mutableListOf<JsonObject>()
        if (followSet.isNotEmpty()) filters += hashtagFilter(followSet.sorted().take(AUTHORS_CAP))
        val others = trust?.minus(followSet)
        when {
            // Trusted authors by name, then open for those past the cap (iOS `trustScopedFilters`).
            !others.isNullOrEmpty() -> {
                filters += hashtagFilter(others.sorted().take(AUTHORS_CAP))
                filters += hashtagFilter(null)
            }
            trust == null || followSet.size > AUTHORS_CAP -> filters += hashtagFilter(null)
        }
        if (filters.isEmpty()) {
            _isLoading.value = false
            return
        }
        val wantedAuthors = trust?.let { it + followSet }
        val blocked = configStore.config.value.blockedForActiveAccount()
            .mapNotNull { nostrService.npubToHex(it) }
            .toSet()
        val relays = configStore.config.value.activeFeedRelays
            .ifEmpty { listOf("wss://relay.primal.net", "wss://nos.lol") }

        val subId = "hashtag-${System.currentTimeMillis().toString(36)}"
        val req = buildJsonArray {
            add(JsonPrimitive("REQ"))
            add(JsonPrimitive(subId))
            filters.forEach { add(it) }
        }.toString()

        for (url in relays) {
            val client = WebSocketClient(url, viewModelScope)
            clients += client
            jobs += viewModelScope.launch(Dispatchers.Default) {
                client.messages.collect { raw -> onMessage(raw, subId, gen, blocked, wantedAuthors) }
            }
            // Sent again after a reconnect, so the feed stays live.
            jobs += viewModelScope.launch {
                client.connectionState.collect { state ->
                    if (state == WebSocketClient.ConnectionState.CONNECTED) client.send(req)
                }
            }
            client.connect()
        }
        jobs += viewModelScope.launch {
            delay(LOADING_TIMEOUT_MS)
            if (gen == generation) _isLoading.value = false
        }
    }

    private fun hashtagFilter(authors: List<String>?): JsonObject = buildJsonObject {
        putJsonArray("kinds") { add(JsonPrimitive(1)) }
        // NIP-24 says t tags are lowercase; [tag] already is.
        putJsonArray("#t") { add(JsonPrimitive(tag)) }
        put("limit", LIMIT)
        if (authors != null) putJsonArray("authors") { authors.forEach { add(JsonPrimitive(it)) } }
    }

    private fun stop() {
        jobs.forEach { it.cancel() }
        jobs.clear()
        clients.forEach { it.disconnect() }
        clients.clear()
    }

    override fun onCleared() {
        stop()
        super.onCleared()
    }

    /**
     * Runs off Main. Only what was asked for: a relay can send validly signed
     * posts that lack the tag, or come from people outside the requested
     * authors, and any event under any author, so every signature is checked.
     */
    private fun onMessage(raw: String, subId: String, gen: Int, blocked: Set<String>, authors: Set<String>?) {
        val array = try {
            json.parseToJsonElement(raw) as? JsonArray
        } catch (e: Exception) {
            Log.w(TAG, "unparseable relay message: ${e.message}")
            null
        } ?: return
        if (array.size < 2 || array[1].jsonPrimitive.contentOrNull != subId) return
        when (array[0].jsonPrimitive.contentOrNull) {
            "EOSE" -> if (gen == generation) _isLoading.value = false
            "EVENT" -> {
                val event = array.getOrNull(2) as? JsonObject ?: return
                val note = parseNote(event, blocked, authors) ?: return
                insert(note, gen)
            }
        }
    }

    private fun parseNote(event: JsonObject, blocked: Set<String>, authors: Set<String>?): FeedNote? = try {
        val id = event["id"]?.jsonPrimitive?.contentOrNull
        val pubkey = event["pubkey"]?.jsonPrimitive?.contentOrNull
        val content = event["content"]?.jsonPrimitive?.contentOrNull
        val createdAt = event["created_at"]?.jsonPrimitive?.longOrNull
        val kind = event["kind"]?.jsonPrimitive?.contentOrNull?.toIntOrNull()
        val tags = event["tags"]?.jsonArray?.map { t -> t.jsonArray.map { it.jsonPrimitive.contentOrNull.orEmpty() } }
        if (id == null || pubkey == null || content == null || createdAt == null || kind != 1 || tags == null) {
            null
        } else if (authors != null && pubkey !in authors) {
            null
        } else if (tags.none { it.size >= 2 && it[0] == "t" && it[1].lowercase() == tag }) {
            null
        } else if (FeedNote.isNoiseOrSpam(content, tags)) {
            null
        } else {
            val note = FeedNote.fromEvent(id, pubkey, content, tags, createdAt, kind)
            note.takeIf {
                !FeedFilterEngine.involvesBlocked(it, blocked) { ref -> feedService.findNote(ref)?.pubkey } &&
                    HavenBridge.verifyEvent(event.toString())
            }
        }
    } catch (e: Exception) {
        Log.w(TAG, "unusable event: ${e.message}")
        null
    }

    private fun insert(note: FeedNote, gen: Int) {
        val updated = synchronized(lock) {
            if (gen != generation || !seen.add(note.id)) return
            val target = if (note.pubkey in follows) _fromFollows else _fromOthers
            val current = target.value
            val index = current.indexOfFirst { it.createdAt < note.createdAt }.let { if (it < 0) current.size else it }
            val list = current.toMutableList().apply { add(index, note) }
            val capped = if (list.size > MAX_NOTES) list.subList(0, MAX_NOTES).toList() else list
            target.value = capped
            _isLoading.value = false
            requestedAuthors.add(note.pubkey)
        }
        if (updated) nostrService.fetchMissingProfiles(listOf(note.pubkey))
    }

    // ── Engagement (same services as the feed, search and profile) ────────

    fun clearToast() { _toast.value = null }

    fun likeNote(noteId: String) {
        viewModelScope.launch { feedService.likeNote(noteId) }
    }

    fun repostNote(noteId: String) {
        viewModelScope.launch { feedService.repostNote(noteId) }
    }

    fun zapNote(noteId: String, notePubkey: String) {
        viewModelScope.launch {
            val result = zapSendService.zapNote(noteId, notePubkey, DEFAULT_ZAP_SATS)
            _toast.value = result.fold(
                onSuccess = {
                    ZapFlight.launch(noteId)
                    "Zapped $DEFAULT_ZAP_SATS sats"
                },
                onFailure = { "Zap failed: ${it.message ?: "unknown error"}" },
            )
        }
    }

    fun quotedNoteFor(identifier: String): FeedNote? = feedService.quotedNoteFor(identifier)

    fun fetchMissingQuotedNotes(identifiers: List<String>) =
        feedService.fetchMissingQuotedNotes(identifiers)

    fun fetchMissingQuotedProfiles(identifiers: List<String>) =
        feedService.fetchMissingQuotedProfiles(identifiers)
}

@OptIn(ExperimentalMaterial3Api::class)
@Composable
fun HashtagFeedScreen(
    onNoteClick: (String) -> Unit,
    onArticleClick: (String) -> Unit,
    onProfileClick: (String) -> Unit,
    onReply: (String) -> Unit,
    onQuote: (String) -> Unit,
    onBack: () -> Unit,
    viewModel: HashtagFeedViewModel = hiltViewModel(),
) {
    val fromFollows by viewModel.fromFollows.collectAsState()
    val fromOthers by viewModel.fromOthers.collectAsState()
    val notes = remember(fromFollows, fromOthers) { fromFollows + fromOthers }
    val isLoading by viewModel.isLoading.collectAsState()
    val everyone by viewModel.globalShowsEveryone.collectAsState()
    var showEveryoneWarning by remember { mutableStateOf(false) }
    val profiles by viewModel.profiles.collectAsState()
    val quotedNotesCache by viewModel.quotedNotesCache.collectAsState()
    val likedIds by viewModel.likedEventIds.collectAsState()
    val repostedIds by viewModel.repostedEventIds.collectAsState()
    val toast by viewModel.toast.collectAsState()
    val colors = LocalNostrVaultColors.current
    val context = LocalContext.current
    val tag = viewModel.tag

    LaunchedEffect(toast) {
        toast?.let {
            Toast.makeText(context, it, Toast.LENGTH_SHORT).show()
            viewModel.clearToast()
        }
    }

    // Embedded quoted notes (nostr:note1.../nevent1...) and their authors.
    LaunchedEffect(notes) {
        val quotedIds = notes.flatMap { it.quotedEventIds }.distinct()
        if (quotedIds.isNotEmpty()) viewModel.fetchMissingQuotedNotes(quotedIds)
    }
    LaunchedEffect(notes, quotedNotesCache) {
        val quotedIds = notes.flatMap { it.quotedEventIds }.distinct()
        if (quotedIds.isNotEmpty()) viewModel.fetchMissingQuotedProfiles(quotedIds)
    }

    GlassScaffold(
        toolbar = {
            Column(
                modifier = Modifier
                    .fillMaxWidth()
                    .statusBarsPadding()
                    .padding(horizontal = 12.dp, vertical = 8.dp),
            ) {
                Row(
                    verticalAlignment = Alignment.CenterVertically,
                    modifier = Modifier.fillMaxWidth(),
                ) {
                    GlassPill {
                        IconButton(onClick = onBack, modifier = Modifier.size(40.dp)) {
                            Icon(NostrVaultIcons.Back, "Back", tint = PrimaryText, modifier = Modifier.size(25.dp))
                        }
                    }
                    Spacer(Modifier.width(12.dp))
                    Text(
                        text = "#$tag",
                        color = PrimaryText,
                        fontSize = 17.sp,
                        fontWeight = FontWeight.SemiBold,
                        maxLines = 1,
                        overflow = TextOverflow.Ellipsis,
                        modifier = Modifier.weight(1f),
                    )
                    // The app-wide shield, as on Global: leaving the Web of
                    // Trust goes through the warning, coming back does not.
                    GlassPill {
                        IconButton(
                            onClick = {
                                if (everyone) viewModel.setGlobalShowsEveryone(false) else showEveryoneWarning = true
                            },
                            modifier = Modifier
                                .size(40.dp)
                                .semantics { stateDescription = if (everyone) "Everyone" else "Web of Trust" },
                        ) {
                            Icon(
                                imageVector = if (everyone) NostrVaultIcons.TrustOff else NostrVaultIcons.TrustShield,
                                contentDescription = if (everyone) {
                                    "Everyone: unfiltered posts. Tap for your Web of Trust"
                                } else {
                                    "Web of Trust: people you follow and the people they follow. Tap for everyone"
                                },
                                tint = if (everyone) ZapOrange else colors.primary,
                                modifier = Modifier.size(20.dp),
                            )
                        }
                    }
                }
            }
        },
    ) { padding ->
        LazyColumn(
            contentPadding = PaddingValues(
                top = padding.calculateTopPadding(),
                bottom = padding.calculateBottomPadding() + 24.dp,
            ),
            modifier = Modifier.fillMaxSize(),
        ) {
            if (notes.isEmpty()) {
                item(key = "hashtag-empty") {
                    Column(
                        horizontalAlignment = Alignment.CenterHorizontally,
                        modifier = Modifier
                            .fillMaxWidth()
                            .padding(top = 60.dp, start = 32.dp, end = 32.dp),
                    ) {
                        when {
                            isLoading -> CircularProgressIndicator(color = colors.primary)
                            else -> {
                                Icon(
                                    imageVector = NostrVaultIcons.TagIcon,
                                    contentDescription = null,
                                    tint = SecondaryText,
                                    modifier = Modifier.size(28.dp),
                                )
                                Spacer(Modifier.height(10.dp))
                                Text(
                                    text = if (everyone) "No posts tagged #$tag yet"
                                    else "No posts tagged #$tag from people you follow or your network yet",
                                    color = SecondaryText,
                                    fontSize = 15.sp,
                                    textAlign = TextAlign.Center,
                                )
                                if (!everyone) {
                                    Spacer(Modifier.height(6.dp))
                                    Text("The shield above shows everyone.", color = SecondaryText, fontSize = 13.sp)
                                }
                            }
                        }
                    }
                }
            }

            if (fromFollows.isNotEmpty()) {
                item(key = "hashtag-follows-header") { HashtagSectionHeader("From people you follow") }
            }
            items(fromFollows, key = { it.id }) { note ->
                HashtagNote(note, quotedNotesCache, profiles, likedIds, repostedIds, viewModel,
                    onNoteClick, onArticleClick, onProfileClick, onReply, onQuote)
            }
            if (fromOthers.isNotEmpty()) {
                item(key = "hashtag-others-header") {
                    HashtagSectionHeader(if (everyone) "More from everyone" else "More from your network")
                }
            }
            items(fromOthers, key = { it.id }) { note ->
                HashtagNote(note, quotedNotesCache, profiles, likedIds, repostedIds, viewModel,
                    onNoteClick, onArticleClick, onProfileClick, onReply, onQuote)
            }
        }
    }

    if (showEveryoneWarning) {
        AlertDialog(
            onDismissRequest = { showEveryoneWarning = false },
            title = { Text("Sensitive Content Warning") },
            text = {
                Text("Everyone shows posts from people outside your Web of Trust, unfiltered. Expect spam and sensitive content.")
            },
            confirmButton = {
                TextButton(
                    onClick = {
                        viewModel.setGlobalShowsEveryone(true)
                        showEveryoneWarning = false
                    },
                ) { Text("Proceed", color = ErrorRed) }
            },
            dismissButton = {
                TextButton(onClick = { showEveryoneWarning = false }) { Text("Cancel") }
            },
        )
    }
}

@Composable
private fun HashtagSectionHeader(title: String) {
    Text(
        text = title,
        color = SecondaryText,
        fontSize = 13.sp,
        fontWeight = FontWeight.SemiBold,
        modifier = Modifier
            .fillMaxWidth()
            .padding(start = 16.dp, end = 16.dp, top = 16.dp, bottom = 6.dp),
    )
}

@Composable
private fun HashtagNote(
    note: FeedNote,
    quotedNotesCache: Map<String, FeedNote>,
    profiles: Map<String, FeedProfile>,
    likedIds: Set<String>,
    repostedIds: Set<String>,
    viewModel: HashtagFeedViewModel,
    onNoteClick: (String) -> Unit,
    onArticleClick: (String) -> Unit,
    onProfileClick: (String) -> Unit,
    onReply: (String) -> Unit,
    onQuote: (String) -> Unit,
) {
    val quotedNotesMap = remember(note.id, note.quotedEventIds, quotedNotesCache) {
        note.quotedEventIds.mapNotNull { qid ->
            viewModel.quotedNoteFor(qid)?.let { qid to it }
        }.toMap()
    }
    NoteCard(
        note = note,
        profile = profiles[note.pubkey],
        profiles = profiles,
        quotedNotes = quotedNotesMap,
        isLiked = note.effectiveEventId in likedIds,
        isReposted = note.effectiveEventId in repostedIds,
        onNoteClick = onNoteClick,
        onArticleClick = onArticleClick,
        onProfileClick = onProfileClick,
        onLike = viewModel::likeNote,
        onRepost = viewModel::repostNote,
        onReply = onReply,
        onQuote = onQuote,
        onZap = { viewModel.zapNote(note.effectiveEventId, note.pubkey) },
    )
    HorizontalDivider(color = SeparatorColor, thickness = 0.5.dp)
}
