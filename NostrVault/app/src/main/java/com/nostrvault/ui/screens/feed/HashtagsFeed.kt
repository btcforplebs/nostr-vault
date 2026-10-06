package com.nostrvault.ui.screens.feed

import android.util.Log
import android.widget.Toast
import androidx.compose.foundation.ExperimentalFoundationApi
import androidx.compose.foundation.background
import androidx.compose.foundation.clickable
import androidx.compose.foundation.combinedClickable
import androidx.compose.foundation.horizontalScroll
import androidx.compose.foundation.layout.*
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.LazyListState
import androidx.compose.foundation.lazy.items
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material3.*
import androidx.compose.runtime.*
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.alpha
import androidx.compose.ui.draw.clip
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.hapticfeedback.HapticFeedbackType
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.platform.LocalHapticFeedback
import androidx.compose.ui.semantics.Role
import androidx.compose.ui.semantics.selected
import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.style.TextAlign
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import androidx.lifecycle.viewModelScope
import com.nostrvault.data.local.ConfigStore
import com.nostrvault.data.model.FeedLayoutMode
import com.nostrvault.data.model.FeedNote
import com.nostrvault.data.model.FeedThread
import com.nostrvault.data.model.FeedThreadGrouping
import com.nostrvault.ui.components.CompactNoteCard
import com.nostrvault.ui.components.FeedThreadCard
import com.nostrvault.data.remote.WebSocketClient
import com.nostrvault.relay.HavenBridge
import com.nostrvault.service.FeedService
import com.nostrvault.service.HashtagSuggestions
import com.nostrvault.service.InterestListService
import com.nostrvault.service.NostrService
import com.nostrvault.service.ZapSendService
import com.nostrvault.ui.screens.HashtagNote
import com.nostrvault.ui.screens.HashtagNotesViewModel
import com.nostrvault.ui.screens.HashtagSectionHeader
import com.nostrvault.ui.theme.*
import dagger.hilt.android.lifecycle.HiltViewModel
import kotlinx.coroutines.CompletableDeferred
import kotlinx.coroutines.CoroutineStart
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.async
import kotlinx.coroutines.awaitAll
import kotlinx.coroutines.coroutineScope
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.SharingStarted
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.asStateFlow
import kotlinx.coroutines.flow.collectLatest
import kotlinx.coroutines.flow.combine
import kotlinx.coroutines.flow.distinctUntilChanged
import kotlinx.coroutines.flow.map
import kotlinx.coroutines.flow.stateIn
import kotlinx.coroutines.launch
import kotlinx.coroutines.withTimeoutOrNull
import kotlinx.serialization.json.JsonArray
import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.JsonPrimitive
import kotlinx.serialization.json.buildJsonArray
import kotlinx.serialization.json.buildJsonObject
import kotlinx.serialization.json.contentOrNull
import kotlinx.serialization.json.jsonArray
import kotlinx.serialization.json.jsonPrimitive
import kotlinx.serialization.json.put
import kotlinx.serialization.json.putJsonArray
import java.util.concurrent.ConcurrentHashMap
import javax.inject.Inject

/**
 * The Hashtags feed: posts in the hashtags you follow (your NIP-51 interest
 * list, kind 10015), under the same scope rules as the hashtag sheet. Not a
 * view of the note list: like Music and Live, the note subscription is left
 * alone while it shows, and this runs its own REQ. iOS: HashtagsFeedView.
 */
@HiltViewModel
class HashtagsFeedViewModel @Inject constructor(
    nostrService: NostrService,
    configStore: ConfigStore,
    feedService: FeedService,
    zapSendService: ZapSendService,
    private val interestListService: InterestListService,
) : HashtagNotesViewModel(nostrService, configStore, feedService, zapSendService) {

    companion object {
        private const val TAG = "HashtagsFeed"
        private const val SUGGESTION_NOTES = 500
        private const val SUGGESTIONS_TIMEOUT_MS = 6_000L
    }

    val followedTags: StateFlow<List<String>> = interestListService.hashtags

    /** The tag the chips narrow to; null is All. */
    private val _selected = MutableStateFlow<String?>(null)
    val selected: StateFlow<String?> = _selected.asStateFlow()

    /** On screen. Off, the subscription closes; the ViewModel outlives the mode. */
    private val active = MutableStateFlow(false)

    /** Tags of recent posts by your follows, one list per post: what suggestions count. */
    private val suggestionSource = MutableStateFlow<List<List<List<String>>>>(emptyList())
    private var suggestionsFor: List<String>? = null

    val suggestions: StateFlow<List<String>> = combine(suggestionSource, followedTags) { notes, followed ->
        HashtagSuggestions.top(notes, followed)
    }.stateIn(viewModelScope, SharingStarted.Eagerly, emptyList())

    private val _suggestionsLoading = MutableStateFlow(false)
    val suggestionsLoading: StateFlow<Boolean> = _suggestionsLoading.asStateFlow()

    /** Tags with a follow or unfollow in flight. */
    private val _saving = MutableStateFlow<Set<String>>(emptySet())
    val saving: StateFlow<Set<String>> = _saving.asStateFlow()

    private val _followFailed = MutableStateFlow(false)
    val followFailed: StateFlow<Boolean> = _followFailed.asStateFlow()

    init {
        // Unfollowed while narrowed to it: back to All.
        viewModelScope.launch {
            followedTags.collect { tags -> if (_selected.value?.let { it !in tags } == true) _selected.value = null }
        }
        observe(
            combine(followedTags, _selected) { tags, chosen ->
                if (chosen != null && chosen in tags) listOf(chosen) else tags
            },
            active,
        )
        // Suggestions are only for the empty state, asked once per follow list.
        viewModelScope.launch {
            combine(
                active,
                followedTags.map { it.isEmpty() }.distinctUntilChanged(),
                feedService.followedPubkeys,
            ) { on, none, follows -> if (on && none) follows.sorted().take(AUTHORS_CAP) else null }
                .distinctUntilChanged()
                .collectLatest { authors ->
                    if (authors.isNullOrEmpty() || authors == suggestionsFor) return@collectLatest
                    _suggestionsLoading.value = true
                    try {
                        suggestionSource.value = fetchFollowsTags(authors)
                        suggestionsFor = authors
                    } finally {
                        _suggestionsLoading.value = false
                    }
                }
        }
    }

    /** Thread cards look up ancestors the hashtag page did not carry. */
    fun findNote(id: String): FeedNote? = feedService.findNote(id)
    fun fetchMissingNote(id: String) = feedService.fetchMissingNote(id)
    fun blockedPubkeys(): Set<String> = feedService.blockedHexForActiveAccount()

    fun setActive(on: Boolean) {
        active.value = on
        if (on) interestListService.refreshIfNeeded()
    }

    fun select(tag: String?) { _selected.value = tag }

    fun setFollowing(tag: String, followed: Boolean) {
        if (tag in _saving.value) return
        _saving.value = _saving.value + tag
        viewModelScope.launch {
            try {
                if (!interestListService.setFollowing(tag, followed)) _followFailed.value = true
            } finally {
                _saving.value = _saving.value - tag
            }
        }
    }

    fun clearFollowFailed() { _followFailed.value = false }

    /**
     * One-shot: recent kind-1 posts by [authors], for their `t` tags. Ends at
     * every relay's EOSE or the timeout, whichever is first; whatever arrived
     * by then counts. Signatures are checked, so a relay cannot plant tags.
     */
    private suspend fun fetchFollowsTags(authors: List<String>): List<List<List<String>>> {
        val relays = configStore.config.value.activeFeedRelays
            .ifEmpty { listOf("wss://relay.primal.net", "wss://nos.lol") }
        val authorSet = authors.toSet()
        val subId = "hashtag-suggest-${System.currentTimeMillis().toString(36)}"
        val req = buildJsonArray {
            add(JsonPrimitive("REQ"))
            add(JsonPrimitive(subId))
            add(
                buildJsonObject {
                    putJsonArray("kinds") { add(JsonPrimitive(1)) }
                    putJsonArray("authors") { authors.forEach { add(JsonPrimitive(it)) } }
                    put("limit", SUGGESTION_NOTES)
                },
            )
        }.toString()
        val byId = ConcurrentHashMap<String, List<List<String>>>()
        val clients = relays.map { WebSocketClient(it, viewModelScope) }
        try {
            withTimeoutOrNull(SUGGESTIONS_TIMEOUT_MS) {
                coroutineScope {
                    clients.map { client ->
                        async(Dispatchers.Default) {
                            val done = CompletableDeferred<Unit>()
                            val reader = launch(start = CoroutineStart.UNDISPATCHED) {
                                client.messages.collect { raw ->
                                    if (onSuggestionMessage(raw, subId, authorSet, byId)) done.complete(Unit)
                                }
                            }
                            val sender = launch(start = CoroutineStart.UNDISPATCHED) {
                                client.connectionState.collect { state ->
                                    if (state == WebSocketClient.ConnectionState.CONNECTED) client.send(req)
                                }
                            }
                            client.connect()
                            try {
                                done.await()
                            } finally {
                                reader.cancel()
                                sender.cancel()
                            }
                        }
                    }.awaitAll()
                }
            }
        } finally {
            clients.forEach { it.disconnect() }
        }
        return byId.values.toList()
    }

    /** True once this relay is finished (EOSE or CLOSED). */
    private fun onSuggestionMessage(
        raw: String,
        subId: String,
        authors: Set<String>,
        byId: MutableMap<String, List<List<String>>>,
    ): Boolean {
        val array = try {
            json.parseToJsonElement(raw) as? JsonArray
        } catch (e: Exception) {
            Log.w(TAG, "unparseable relay message: ${e.message}")
            null
        } ?: return false
        if (array.size < 2 || array[1].jsonPrimitive.contentOrNull != subId) return false
        return when (array[0].jsonPrimitive.contentOrNull) {
            "EOSE", "CLOSED" -> true
            "EVENT" -> {
                try {
                    val event = array.getOrNull(2) as? JsonObject ?: return false
                    val id = event["id"]?.jsonPrimitive?.contentOrNull ?: return false
                    val pubkey = event["pubkey"]?.jsonPrimitive?.contentOrNull
                    val kind = event["kind"]?.jsonPrimitive?.contentOrNull?.toIntOrNull()
                    if (kind != 1 || pubkey !in authors || byId.containsKey(id)) return false
                    val tags = event["tags"]?.jsonArray
                        ?.map { t -> t.jsonArray.map { it.jsonPrimitive.contentOrNull.orEmpty() } }
                        ?: return false
                    if (HavenBridge.verifyEvent(event.toString())) byId[id] = tags
                } catch (e: Exception) {
                    Log.w(TAG, "unusable event: ${e.message}")
                }
                false
            }
            else -> false
        }
    }
}

/**
 * The Hashtags feed's content: the tag chips, then posts from people you
 * follow and from the rest of your network (or everyone, by the shield).
 * The shield itself is in the feed's top bar, as on Global.
 */
@Composable
internal fun HashtagsFeed(
    viewModel: HashtagsFeedViewModel,
    listState: LazyListState,
    contentPadding: PaddingValues,
    /** The feed's layout button: full cards, compact lines, or conversations. */
    layoutMode: FeedLayoutMode,
    onNoteClick: (String) -> Unit,
    onArticleClick: (String) -> Unit,
    onProfileClick: (String) -> Unit,
    onReply: (String) -> Unit,
    onQuote: (String) -> Unit,
    /** Registers a row's note with the feed so thread and compose screens resolve its id. */
    onCacheNote: (FeedNote) -> Unit,
) {
    val followedTags by viewModel.followedTags.collectAsState()
    val selected by viewModel.selected.collectAsState()
    val fromFollows by viewModel.fromFollows.collectAsState()
    val fromOthers by viewModel.fromOthers.collectAsState()
    val notes = remember(fromFollows, fromOthers) { fromFollows + fromOthers }
    val isLoading by viewModel.isLoading.collectAsState()
    val everyone by viewModel.globalShowsEveryone.collectAsState()
    val profiles by viewModel.profiles.collectAsState()
    val quotedNotesCache by viewModel.quotedNotesCache.collectAsState()
    val likedIds by viewModel.likedEventIds.collectAsState()
    val repostedIds by viewModel.repostedEventIds.collectAsState()
    val toast by viewModel.toast.collectAsState()
    val suggestions by viewModel.suggestions.collectAsState()
    val suggestionsLoading by viewModel.suggestionsLoading.collectAsState()
    val saving by viewModel.saving.collectAsState()
    val hasAccount by viewModel.hasAccount.collectAsState()
    val followFailed by viewModel.followFailed.collectAsState()
    val colors = LocalNostrVaultColors.current
    val context = LocalContext.current

    // The subscription runs only while this feed is showing.
    DisposableEffect(viewModel) {
        viewModel.setActive(true)
        onDispose { viewModel.setActive(false) }
    }

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

    val byId = remember(notes) { notes.associateBy { it.id } }
    // Ids that are not rows (an embedded quote) go through as they are.
    val openNote: (String) -> Unit = { id -> byId[id]?.let(onCacheNote); onNoteClick(id) }
    val reply: (String) -> Unit = { id -> byId[id]?.let(onCacheNote); onReply(id) }
    val quote: (String) -> Unit = { id -> byId[id]?.let(onCacheNote); onQuote(id) }

    // Compact lines open in place first, like the main feed; thread cards
    // share the same open note.
    var openNoteId by remember { mutableStateOf<String?>(null) }
    val threadFolds = remember { mutableStateMapOf<String, Boolean>() }
    val isCompact = layoutMode.usesCondensedRows
    val isThreaded = layoutMode == FeedLayoutMode.THREADED
    // Both sections grouped in one pass, so replies from a follow and from
    // your network land in the same card. A card goes on top when anyone you
    // follow posted in it: follows first still holds, nothing is split.
    val threadSections = remember(isThreaded, fromFollows, fromOthers) {
        if (!isThreaded) null else {
            val followIds = fromFollows.mapTo(HashSet()) { it.id }
            val blocked = viewModel.blockedPubkeys()
            val threads = FeedThreadGrouping.withoutBlocked(
                FeedThreadGrouping.build(fromFollows + fromOthers) { id ->
                    viewModel.findNote(id)?.takeIf { it.pubkey !in blocked }
                },
                blocked,
            ) { id -> viewModel.findNote(id) }
            threads.partition { thread -> thread.entries.any { it.note.id in followIds } }
        }
    }

    val fullRow: @Composable (FeedNote) -> Unit = { note ->
        HashtagNote(note, quotedNotesCache, profiles, likedIds, repostedIds, viewModel,
            openNote, onArticleClick, onProfileClick, reply, quote)
    }
    val noteRow: @Composable (FeedNote) -> Unit = { note ->
        if (isCompact && openNoteId != note.id) {
            CompactNoteCard(
                note = note,
                profile = profiles[note.pubkey],
                profiles = profiles,
                onNoteClick = { id -> openNoteId = id },
                onProfileClick = onProfileClick,
                // iOS: 8pt sides for a compact row, 12pt between rows.
                modifier = Modifier.padding(horizontal = 8.dp, vertical = 6.dp),
            )
        } else {
            fullRow(note)
        }
    }
    val threadRow: @Composable (FeedThread) -> Unit = { thread ->
        FeedThreadCard(
            thread = thread,
            profileFor = { pubkey -> profiles[pubkey] },
            profiles = profiles,
            openNoteId = openNoteId,
            onOpenNoteChange = { id -> openNoteId = id },
            isExpanded = threadFolds[thread.rootId] ?: false,
            onExpandedChange = { expanded -> threadFolds[thread.rootId] = expanded },
            onProfileClick = onProfileClick,
            onOpenThread = { note -> onCacheNote(note); onNoteClick(note.id) },
            onFetchMissingNote = viewModel::fetchMissingNote,
            // iOS: 12pt sides in threaded mode, 12pt between rows.
            modifier = Modifier.padding(horizontal = 12.dp, vertical = 6.dp),
            expandedRow = { note, _ -> fullRow(note) },
        )
    }

    LazyColumn(
        state = listState,
        contentPadding = PaddingValues(
            top = contentPadding.calculateTopPadding(),
            bottom = contentPadding.calculateBottomPadding() + 88.dp,
        ),
        modifier = Modifier.fillMaxSize(),
    ) {
        if (followedTags.isNotEmpty()) item(key = "hashtags-chips") {
            Row(
                horizontalArrangement = Arrangement.spacedBy(8.dp),
                modifier = Modifier
                    .fillMaxWidth()
                    .horizontalScroll(rememberScrollState())
                    .padding(horizontal = 16.dp, vertical = 8.dp),
            ) {
                HashtagChip(title = "All", isOn = selected == null, onClick = { viewModel.select(null) })
                followedTags.forEach { tag ->
                    HashtagChip(
                        title = "#$tag",
                        isOn = selected == tag,
                        onClick = { viewModel.select(tag) },
                        onUnfollow = if (hasAccount && tag !in saving) {
                            { viewModel.setFollowing(tag, false) }
                        } else null,
                    )
                }
            }
        }

        if (followedTags.isEmpty()) {
            item(key = "hashtags-none") {
                HashtagsEmptyHeader("Follow a hashtag to see it here")
            }
            when {
                suggestions.isNotEmpty() -> {
                    item(key = "hashtags-suggest-header") { HashtagSectionHeader("Popular with people you follow") }
                    items(suggestions, key = { "suggest-$it" }) { tag ->
                        SuggestedHashtagRow(
                            tag = tag,
                            enabled = hasAccount && tag !in saving,
                            onFollow = { viewModel.setFollowing(tag, true) },
                        )
                    }
                }
                suggestionsLoading -> item(key = "hashtags-suggest-loading") {
                    Box(Modifier.fillMaxWidth().padding(top = 24.dp), contentAlignment = Alignment.Center) {
                        CircularProgressIndicator(color = colors.primary, modifier = Modifier.size(22.dp), strokeWidth = 2.dp)
                    }
                }
                else -> item(key = "hashtags-hint") {
                    Text(
                        text = "Tap a #hashtag in any post to follow it.",
                        color = SecondaryText,
                        fontSize = 13.sp,
                        textAlign = TextAlign.Center,
                        modifier = Modifier.fillMaxWidth().padding(top = 6.dp, start = 32.dp, end = 32.dp),
                    )
                }
            }
        } else if (notes.isEmpty()) {
            item(key = "hashtags-empty") {
                Column(
                    horizontalAlignment = Alignment.CenterHorizontally,
                    modifier = Modifier
                        .fillMaxWidth()
                        .padding(top = 60.dp, start = 32.dp, end = 32.dp),
                ) {
                    if (isLoading) {
                        CircularProgressIndicator(color = colors.primary)
                    } else {
                        Icon(NostrVaultIcons.TagIcon, contentDescription = null, tint = SecondaryText, modifier = Modifier.size(28.dp))
                        Spacer(Modifier.height(10.dp))
                        Text(
                            text = selected?.let { "No posts tagged #$it yet" } ?: "No posts in your hashtags yet",
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

        val othersTitle = if (everyone) "More from everyone" else "More from your network"
        if (threadSections != null) {
            val (top, rest) = threadSections
            if (top.isNotEmpty()) {
                item(key = "hashtags-follows-header") { HashtagSectionHeader("From people you follow") }
            }
            items(top, key = { "thread-${it.rootId}" }) { threadRow(it) }
            if (rest.isNotEmpty()) {
                item(key = "hashtags-others-header") { HashtagSectionHeader(othersTitle) }
            }
            items(rest, key = { "thread-${it.rootId}" }) { threadRow(it) }
        } else {
            if (fromFollows.isNotEmpty()) {
                item(key = "hashtags-follows-header") { HashtagSectionHeader("From people you follow") }
            }
            items(fromFollows, key = { it.id }) { noteRow(it) }
            if (fromOthers.isNotEmpty()) {
                item(key = "hashtags-others-header") { HashtagSectionHeader(othersTitle) }
            }
            items(fromOthers, key = { it.id }) { noteRow(it) }
        }
    }

    if (followFailed) {
        AlertDialog(
            onDismissRequest = viewModel::clearFollowFailed,
            title = { Text("Couldn't save") },
            text = { Text("Your relays didn't answer, so your hashtag list wasn't changed. Try again in a moment.") },
            confirmButton = { TextButton(onClick = viewModel::clearFollowFailed) { Text("OK") } },
        )
    }
}

@Composable
private fun HashtagsEmptyHeader(text: String) {
    Column(
        horizontalAlignment = Alignment.CenterHorizontally,
        modifier = Modifier
            .fillMaxWidth()
            .padding(top = 48.dp, bottom = 8.dp, start = 32.dp, end = 32.dp),
    ) {
        Icon(NostrVaultIcons.TagIcon, contentDescription = null, tint = SecondaryText, modifier = Modifier.size(28.dp))
        Spacer(Modifier.height(10.dp))
        Text(text, color = SecondaryText, fontSize = 15.sp, textAlign = TextAlign.Center)
    }
}

/**
 * A tag chip, styled like the recipe categories. Long press offers Unfollow
 * (a menu rather than an instant unfollow, so a stray hold costs nothing).
 */
@OptIn(ExperimentalFoundationApi::class)
@Composable
private fun HashtagChip(title: String, isOn: Boolean, onClick: () -> Unit, onUnfollow: (() -> Unit)? = null) {
    val colors = LocalNostrVaultColors.current
    val haptic = LocalHapticFeedback.current
    var menu by remember { mutableStateOf(false) }
    Box {
        Text(
            text = title,
            color = if (isOn) Color.White else colors.primary,
            fontSize = 12.sp,
            fontWeight = FontWeight.SemiBold,
            maxLines = 1,
            modifier = Modifier
                .clip(CircleShape)
                .background(if (isOn) colors.primary else colors.primary.copy(alpha = 0.14f))
                .semantics { selected = isOn }
                .combinedClickable(
                    role = Role.Tab,
                    onClick = onClick,
                    onLongClickLabel = onUnfollow?.let { "Unfollow $title" },
                    onLongClick = onUnfollow?.let {
                        {
                            haptic.performHapticFeedback(HapticFeedbackType.LongPress)
                            menu = true
                        }
                    },
                )
                .padding(horizontal = 12.dp, vertical = 6.dp),
        )
        DropdownMenu(expanded = menu, onDismissRequest = { menu = false }) {
            DropdownMenuItem(
                text = { Text("Unfollow $title") },
                onClick = {
                    menu = false
                    onUnfollow?.invoke()
                },
            )
        }
    }
}

/** One suggested tag with its Follow button, styled like the sheet's. */
@Composable
private fun SuggestedHashtagRow(tag: String, enabled: Boolean, onFollow: () -> Unit) {
    val colors = LocalNostrVaultColors.current
    Row(
        verticalAlignment = Alignment.CenterVertically,
        modifier = Modifier
            .fillMaxWidth()
            .padding(horizontal = 16.dp, vertical = 6.dp),
    ) {
        Text(
            text = "#$tag",
            color = PrimaryText,
            fontSize = 16.sp,
            fontWeight = FontWeight.SemiBold,
            maxLines = 1,
            overflow = TextOverflow.Ellipsis,
            modifier = Modifier.weight(1f),
        )
        Spacer(Modifier.width(8.dp))
        Row(
            verticalAlignment = Alignment.CenterVertically,
            horizontalArrangement = Arrangement.spacedBy(6.dp),
            modifier = Modifier
                .alpha(if (enabled) 1f else 0.5f)
                .clip(RoundedCornerShape(6.dp))
                .background(colors.primary.copy(alpha = 0.12f))
                .clickable(
                    enabled = enabled,
                    onClickLabel = "Follow #$tag",
                    role = Role.Button,
                    onClick = onFollow,
                )
                .padding(horizontal = 12.dp, vertical = 7.dp),
        ) {
            Icon(NostrVaultIcons.Create, contentDescription = null, tint = colors.primary, modifier = Modifier.size(14.dp))
            Text("Follow", color = colors.primary, fontSize = 13.sp, fontWeight = FontWeight.SemiBold)
        }
    }
}
