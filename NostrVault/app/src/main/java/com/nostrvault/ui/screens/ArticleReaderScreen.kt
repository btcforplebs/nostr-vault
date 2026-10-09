package com.nostrvault.ui.screens

import android.widget.Toast
import androidx.compose.foundation.background
import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.*
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.foundation.verticalScroll
import androidx.compose.material3.*
import androidx.compose.runtime.*
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.vector.ImageVector
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.filled.Favorite
import androidx.compose.material.icons.outlined.FavoriteBorder
import androidx.compose.material.icons.outlined.ChatBubbleOutline
import androidx.compose.material.icons.outlined.Bolt
import androidx.compose.material.icons.filled.Bolt
import androidx.compose.material.icons.outlined.BorderColor
import androidx.compose.material.icons.outlined.Share
import androidx.compose.material.icons.outlined.Forum
import androidx.compose.material.icons.automirrored.outlined.Reply
import com.nostrvault.ui.components.engagementCountLabel
import com.nostrvault.ui.components.formatCount
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.layout.ContentScale
import androidx.compose.ui.text.TextStyle
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import androidx.hilt.navigation.compose.hiltViewModel
import androidx.lifecycle.SavedStateHandle
import androidx.lifecycle.ViewModel
import androidx.lifecycle.viewModelScope
import coil.compose.AsyncImage
import com.nostrvault.data.local.ConfigStore
import com.nostrvault.data.model.ArticleEngagement
import com.nostrvault.data.model.ArticleEngagementEvent
import com.nostrvault.data.model.ArticleTallies
import com.nostrvault.data.model.ArticleTally
import com.nostrvault.data.model.ArticleHighlight
import com.nostrvault.data.model.ArticleMeta
import com.nostrvault.data.model.NIP10Thread
import com.nostrvault.relay.HavenBridge
import com.nostrvault.service.ZapSendService
import com.nostrvault.ui.components.AvatarImage
import com.nostrvault.ui.components.CustomZapSheet
import com.nostrvault.ui.components.threadLink
import com.nostrvault.data.model.FeedNote
import com.nostrvault.data.model.FeedProfile
import com.nostrvault.service.FeedService
import com.nostrvault.service.NostrService
import com.nostrvault.ui.theme.*
import dagger.hilt.android.lifecycle.HiltViewModel
import dev.jeziellago.compose.markdowntext.MarkdownText
import android.text.format.DateUtils
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.flow.MutableSharedFlow
import kotlinx.coroutines.flow.update
import kotlinx.serialization.json.JsonArray
import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.JsonPrimitive
import kotlinx.serialization.json.contentOrNull
import kotlinx.serialization.json.longOrNull
import java.util.concurrent.ConcurrentHashMap
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.SharedFlow
import kotlinx.coroutines.launch
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.asStateFlow
import java.text.DateFormat
import java.util.Optional
import javax.inject.Inject

/**
 * Reader for one NIP-23 long-form post.
 *
 * A kind-30023 body is Markdown, and rendering it as the plain text a kind-1
 * note gets would show the reader the syntax instead of the article. The
 * markdown renderer was already a dependency of this project and was not being
 * used anywhere.
 */
@HiltViewModel
class ArticleReaderViewModel @Inject constructor(
    savedStateHandle: SavedStateHandle,
    private val feedService: FeedService,
    private val nostrService: NostrService,
    private val configStore: ConfigStore,
    private val zapSendService: ZapSendService,
) : ViewModel() {

    val noteId: String = savedStateHandle["noteId"] ?: ""

    private companion object {
        /** Highlights already fetched this session, by article id. */
        val highlightCache = ConcurrentHashMap<String, List<ArticleHighlight>>()
        /** Likes, zaps and comments fetched this session, by article id. */
        val engagementCache = ConcurrentHashMap<String, List<ArticleEngagementEvent>>()
    }

    private val _note = MutableStateFlow<FeedNote?>(null)
    val note: StateFlow<FeedNote?> = _note.asStateFlow()

    private val _isLoading = MutableStateFlow(false)
    val isLoading: StateFlow<Boolean> = _isLoading.asStateFlow()

    val profiles: StateFlow<Map<String, FeedProfile>> = nostrService.profiles
    val likedEventIds: StateFlow<Set<String>> = feedService.likedEventIds

    private val _message = MutableSharedFlow<String>(extraBufferCapacity = 4)
    val message: SharedFlow<String> = _message

    private val _zapped = MutableStateFlow(false)
    val zapped: StateFlow<Boolean> = _zapped.asStateFlow()

    /** Sats you zapped from this screen, counted before the receipt arrives. */
    private val _zappedSats = MutableStateFlow(0L)
    val zappedSats: StateFlow<Long> = _zappedSats.asStateFlow()

    val myPubkey: String get() = configStore.activeAccountHexPubkey.value
    /** Wallet settings' default zap, in sats: where the zap sheet starts. */
    val defaultZapSats: Int get() = configStore.config.value.defaultZapAmount

    private val relayHint: String get() = configStore.config.value.nostrURL ?: ""

    /** Same optimistic like as the feed, tagged with the article's `a` coordinate. */
    fun like(note: FeedNote) {
        feedService.likeNote(
            note.id,
            tags = ArticleEngagement.reactionTags(note.id, note.kind, note.pubkey, note.tags, relayHint),
        )
    }

    fun zap(note: FeedNote, amountSats: Int) {
        viewModelScope.launch {
            val coordinate = NIP10Thread.coordinate(note.kind, note.pubkey, note.tags)
            zapSendService.zapNote(note.id, note.pubkey, amountSats, addressTag = coordinate).fold(
                onSuccess = {
                    _zapped.value = true
                    _zappedSats.update { it + amountSats }
                    _message.emit("Zapped $amountSats sats")
                },
                onFailure = { e -> _message.emit(e.message ?: "Zap failed") },
            )
        }
    }

    fun publishHighlight(note: FeedNote, passage: String, context: String, comment: String) {
        val tags = ArticleEngagement.highlightTags(
            note.id, note.kind, note.pubkey, note.tags, relayHint, passage, context, comment,
        )
        viewModelScope.launch {
            val event = runCatching {
                nostrService.signEventAsync(kind = ArticleEngagement.HIGHLIGHT_KIND, content = passage.trim(), tags = tags)
            }.getOrNull()
            if (event != null) {
                nostrService.postEvent(event)
                _message.emit("Highlight published")
                // Show it among everyone else's once a relay has it.
                loadHighlights(note)
            } else {
                _message.emit("Highlight not signed")
            }
        }
    }

    // ── Highlights from the network ──────────────────────────────────

    private val _highlights = MutableStateFlow<List<ArticleHighlight>>(emptyList())
    /** Other people's highlights of this article, newest first. */
    val highlights: StateFlow<List<ArticleHighlight>> = _highlights.asStateFlow()

    /**
     * The article's relay, the feed relays and the author's outbox: where a
     * highlight of it is likely to have been sent.
     */
    private fun highlightRelays(note: FeedNote): List<String> {
        val config = configStore.config.value
        val candidates = buildList {
            config.nostrURL?.let { add(it) }
            addAll(config.readRelays)
            addAll(nostrService.outboxRelays.value[note.pubkey].orEmpty())
        }
        return candidates.map { it.trim() }
            .filter { it.isNotEmpty() }
            .distinctBy { it.lowercase().trimEnd('/') }
            .take(8)
    }

    /**
     * Fetch highlights of [note], showing them as each relay answers rather
     * than after the slowest one, which could hold the list back for the
     * whole timeout. A reopened article shows the last result at once.
     */
    fun loadHighlights(note: FeedNote) {
        highlightCache[note.id]?.let { cached -> _highlights.update { if (cached.size >= it.size) cached else it } }
        val coordinate = NIP10Thread.coordinate(note.kind, note.pubkey, note.tags)
        // Each event is checked once, however many snapshots it appears in.
        val checked = ConcurrentHashMap<String, Optional<ArticleHighlight>>()
        fun show(events: List<JsonObject>): List<ArticleHighlight> {
            val found = ArticleEngagement.shown(events.mapNotNull { ev ->
                val id = (ev["id"] as? JsonPrimitive)?.contentOrNull ?: return@mapNotNull null
                checked.getOrPut(id) { Optional.ofNullable(parseHighlight(ev, note.id, coordinate)) }.orElse(null)
            })
            // An earlier, smaller snapshot can finish after a later one.
            _highlights.update { if (found.size >= it.size) found else it }
            val profiles = nostrService.profiles.value
            val missing = found.map { it.pubkey }.distinct().filter { it !in profiles }
            if (missing.isNotEmpty()) nostrService.fetchMissingProfiles(missing)
            return found
        }
        viewModelScope.launch(Dispatchers.Default) {
            val events = nostrService.queryRawEvents(
                filters = ArticleEngagement.highlightFilters(note.id, coordinate),
                relayUrls = highlightRelays(note),
                onProgress = { show(it) },
            )
            highlightCache[note.id] = show(events)
        }
    }

    /** A signed 9802 that points at this article and isn't spam, or null. */
    private fun parseHighlight(ev: JsonObject, articleId: String, coordinate: String?): ArticleHighlight? {
        fun str(key: String) = (ev[key] as? JsonPrimitive)?.contentOrNull
        val id = str("id") ?: return null
        val pubkey = str("pubkey") ?: return null
        val content = str("content") ?: return null
        val kind = (ev["kind"] as? JsonPrimitive)?.contentOrNull?.toIntOrNull() ?: return null
        val createdAt = (ev["created_at"] as? JsonPrimitive)?.longOrNull ?: return null
        val tags = (ev["tags"] as? JsonArray)?.map { tag ->
            (tag as? JsonArray)?.mapNotNull { (it as? JsonPrimitive)?.contentOrNull }.orEmpty()
        } ?: return null
        // Spam dropped the same way the thread view drops it.
        if (FeedNote.isNoiseOrSpam(content, tags)) return null
        val highlight = ArticleHighlight.from(kind, id, pubkey, content, createdAt, tags, articleId, coordinate)
            ?: return null
        return highlight.takeIf { HavenBridge.verifyEvent(ev.toString()) }
    }

    // ── Likes, zaps and comments from the network ────────────────────

    private val _tally = MutableStateFlow(ArticleTally())
    val tally: StateFlow<ArticleTally> = _tally.asStateFlow()

    /**
     * Fetch the article's likes, zaps and comments from the relays highlights
     * come from, showing each relay's answer as it lands. A reopened article
     * shows the last result at once while the relays are asked again.
     */
    fun loadEngagement(note: FeedNote) {
        val coordinate = NIP10Thread.coordinate(note.kind, note.pubkey, note.tags)
        // Each event is checked once, however many snapshots it appears in.
        val checked = ConcurrentHashMap<String, Optional<ArticleEngagementEvent>>()
        fun show(events: List<ArticleEngagementEvent>) {
            val found = ArticleTallies.tally(events, note.id, coordinate)
            // An earlier, smaller snapshot can finish after a later one.
            _tally.update { if (found.size >= it.size) found else it }
            val profiles = nostrService.profiles.value
            val missing = found.topLevelComments.map { it.pubkey }.distinct().filter { it !in profiles }
            if (missing.isNotEmpty()) nostrService.fetchMissingProfiles(missing)
        }
        fun parsed(raw: List<JsonObject>) = raw.mapNotNull { ev ->
            val id = (ev["id"] as? JsonPrimitive)?.contentOrNull ?: return@mapNotNull null
            checked.getOrPut(id) { Optional.ofNullable(parseEngagement(ev)) }.orElse(null)
        }
        viewModelScope.launch(Dispatchers.Default) {
            val earlier = engagementCache[note.id].orEmpty()
            if (earlier.isNotEmpty()) show(earlier)
            val events = nostrService.queryRawEvents(
                filters = ArticleTallies.engagementFilters(note.id, coordinate),
                relayUrls = highlightRelays(note),
                onProgress = { show(earlier + parsed(it)) },
            )
            // Keep what an earlier load found if a relay this time came back short.
            val merged = (earlier + parsed(events)).associateBy { it.id }.values.toList()
            engagementCache[note.id] = merged
            show(merged)
        }
    }

    /** A signed like, zap receipt or comment that isn't spam, or null. */
    private fun parseEngagement(ev: JsonObject): ArticleEngagementEvent? {
        fun str(key: String) = (ev[key] as? JsonPrimitive)?.contentOrNull
        val id = str("id") ?: return null
        val pubkey = str("pubkey") ?: return null
        val content = str("content") ?: return null
        val kind = (ev["kind"] as? JsonPrimitive)?.contentOrNull?.toIntOrNull() ?: return null
        val createdAt = (ev["created_at"] as? JsonPrimitive)?.longOrNull ?: return null
        val tags = (ev["tags"] as? JsonArray)?.map { tag ->
            (tag as? JsonArray)?.mapNotNull { (it as? JsonPrimitive)?.contentOrNull }.orEmpty()
        } ?: return null
        // Spam comments are dropped the same way the thread view drops them.
        val isComment = kind == ArticleTallies.COMMENT_KIND || kind == ArticleTallies.NOTE_KIND
        if (isComment && FeedNote.isNoiseOrSpam(content, tags)) return null
        if (!HavenBridge.verifyEvent(ev.toString())) return null
        return ArticleEngagementEvent(id, kind, pubkey, content, createdAt, tags)
    }

    /** Makes [comment] resolvable by id for the note screen; returns that id. */
    fun prepareOpen(comment: ArticleEngagementEvent): String {
        feedService.cacheNote(comment.toNote())
        return comment.id
    }

    /** Makes [highlight] resolvable by id for the compose screen; returns that id. */
    fun prepareComment(highlight: ArticleHighlight): String {
        feedService.cacheNote(highlight.toNote())
        return highlight.id
    }

    init {
        // Same two-step the note screen uses: the in-memory feed first, then
        // the relays, so an article opened from a link rather than from the
        // list still resolves.
        val cached = feedService.findNote(noteId)
        if (cached != null) {
            _note.value = cached
        } else {
            _isLoading.value = true
            nostrService.fetchNoteById(noteId, onRawEvent = feedService::cacheRawEvent) { fetched ->
                _isLoading.value = false
                if (fetched != null) {
                    _note.value = fetched
                    feedService.cacheNote(fetched)
                }
            }
        }
    }
}

@OptIn(ExperimentalMaterial3Api::class)
@Composable
fun ArticleReaderScreen(
    onBack: () -> Unit,
    onProfileClick: (String) -> Unit,
    onComment: (String) -> Unit,
    onNoteClick: (String) -> Unit,
    viewModel: ArticleReaderViewModel = hiltViewModel(),
) {
    val note by viewModel.note.collectAsState()
    val liked by viewModel.likedEventIds.collectAsState()
    val zapped by viewModel.zapped.collectAsState()
    val context = LocalContext.current
    var highlighting by remember { mutableStateOf(false) }
    var highlightContext by remember { mutableStateOf<String?>(null) }
    var showZapSheet by remember { mutableStateOf(false) }
    val zapSheetState = rememberModalBottomSheetState(skipPartiallyExpanded = true)

    LaunchedEffect(Unit) {
        viewModel.message.collect { Toast.makeText(context, it, Toast.LENGTH_SHORT).show() }
    }
    val isLoading by viewModel.isLoading.collectAsState()
    val profiles by viewModel.profiles.collectAsState()
    val highlights by viewModel.highlights.collectAsState()
    val tally by viewModel.tally.collectAsState()
    val zappedSats by viewModel.zappedSats.collectAsState()
    // Back from composing a comment: ask again so it shows.
    var resumed by remember { mutableStateOf(0) }
    val lifecycleOwner = androidx.lifecycle.compose.LocalLifecycleOwner.current
    DisposableEffect(lifecycleOwner) {
        val observer = androidx.lifecycle.LifecycleEventObserver { _, event ->
            if (event == androidx.lifecycle.Lifecycle.Event.ON_RESUME) resumed++
        }
        lifecycleOwner.lifecycle.addObserver(observer)
        onDispose { lifecycleOwner.lifecycle.removeObserver(observer) }
    }
    var shownHighlights by remember { mutableStateOf<List<ArticleHighlight>?>(null) }
    val highlightSheetState = rememberModalBottomSheetState()
    val commentOnHighlight: (ArticleHighlight) -> Unit = { h ->
        shownHighlights = null
        onComment(viewModel.prepareComment(h))
    }
    val colors = LocalNostrVaultColors.current

    Scaffold(
        containerColor = WindowBackground,
        topBar = {
            TopAppBar(
                title = { Text("Article", color = PrimaryText, fontSize = 17.sp) },
                navigationIcon = {
                    IconButton(onClick = onBack) {
                        Icon(NostrVaultIcons.Back, contentDescription = "Back", tint = colors.primary)
                    }
                },
                colors = TopAppBarDefaults.topAppBarColors(containerColor = WindowBackground),
            )
        },
    ) { padding ->
        val current = note
        if (current != null) {
            LaunchedEffect(current.id) { viewModel.loadHighlights(current) }
            LaunchedEffect(current.id, resumed) { if (resumed > 0) viewModel.loadEngagement(current) }
        }
        when {
            current != null -> ArticleBody(
                note = current,
                author = profiles[current.pubkey],
                onProfileClick = onProfileClick,
                actions = {
                    val isLiked = current.id in liked
                    ArticleActionBar(
                        liked = isLiked,
                        zapped = zapped,
                        // Your own like and zap count as soon as you make them,
                        // before a relay echoes them back.
                        likeCount = tally.likers.size + if (isLiked && viewModel.myPubkey !in tally.likers) 1 else 0,
                        commentCount = tally.commentCount,
                        zapSats = tally.zapSats + if (tally.zapSats == 0L) zappedSats else 0L,
                        highlighting = highlighting,
                        onLike = { viewModel.like(current) },
                        onComment = { onComment(current.id) },
                        onZap = { showZapSheet = true },
                        onHighlight = { highlighting = !highlighting },
                        onShare = {
                            val ref = HavenBridge.encodeNevent(current.id, current.pubkey, current.kind)
                            val link = ref?.let { threadLink(it) } ?: "nostr:${current.id}"
                            val title = ArticleMeta.from(current).title
                            val intent = android.content.Intent(android.content.Intent.ACTION_SEND).apply {
                                type = "text/plain"
                                putExtra(android.content.Intent.EXTRA_TEXT, "$title\n$link")
                            }
                            context.startActivity(android.content.Intent.createChooser(intent, "Share Article"))
                        },
                    )
                },
                onHighlightBlock = if (highlighting) { text -> highlightContext = text } else null,
                highlights = highlights,
                profiles = profiles,
                onShowHighlights = { shownHighlights = it },
                onCommentHighlight = commentOnHighlight,
                tally = tally,
                onOpenComment = { onNoteClick(viewModel.prepareOpen(it)) },
                modifier = Modifier
                    .padding(padding)
                    .verticalScroll(rememberScrollState())
                    .padding(horizontal = 20.dp),
            )
            isLoading -> Box(
                contentAlignment = Alignment.Center,
                modifier = Modifier.fillMaxSize().padding(padding),
            ) { CircularProgressIndicator(color = colors.primary) }
            else -> Box(
                contentAlignment = Alignment.Center,
                modifier = Modifier.fillMaxSize().padding(padding),
            ) {
                Text(
                    "That article is not in your vault, and no relay answered for it.",
                    color = SecondaryText,
                    fontSize = 14.sp,
                )
            }
        }
    }

    shownHighlights?.let { group ->
        ModalBottomSheet(
            onDismissRequest = { shownHighlights = null },
            sheetState = highlightSheetState,
            containerColor = WindowBackground,
        ) {
            Column(
                verticalArrangement = Arrangement.spacedBy(16.dp),
                modifier = Modifier
                    .verticalScroll(rememberScrollState())
                    .padding(horizontal = 20.dp)
                    .padding(bottom = 32.dp),
            ) {
                Text("Highlights", color = PrimaryText, fontSize = 17.sp, fontWeight = FontWeight.SemiBold)
                group.forEach { h ->
                    HighlightRow(h, profiles[h.pubkey], onComment = { commentOnHighlight(h) })
                }
            }
        }
    }

    val target = note
    if (showZapSheet && target != null) {
        CustomZapSheet(
            sheetState = zapSheetState,
            defaultAmount = viewModel.defaultZapSats,
            onDismiss = { showZapSheet = false },
            onZap = { amount ->
                viewModel.zap(target, amount)
                showZapSheet = false
            },
        )
    }
    val passageContext = highlightContext
    if (passageContext != null && target != null) {
        HighlightDialog(
            initialPassage = passageContext,
            onDismiss = { highlightContext = null },
            onPublish = { passage, comment ->
                viewModel.publishHighlight(target, passage, passageContext, comment)
                highlightContext = null
                highlighting = false
            },
        )
    }
}

@Composable
private fun ArticleActionBar(
    liked: Boolean,
    zapped: Boolean,
    likeCount: Int,
    commentCount: Int,
    zapSats: Long,
    highlighting: Boolean,
    onLike: () -> Unit,
    onComment: () -> Unit,
    onZap: () -> Unit,
    onHighlight: () -> Unit,
    onShare: () -> Unit,
) {
    val colors = LocalNostrVaultColors.current
    Row(horizontalArrangement = Arrangement.spacedBy(10.dp)) {
        ActionPill(if (liked) Icons.Filled.Favorite else Icons.Outlined.FavoriteBorder, "Like",
            if (liked) Color(0xFFE5484D) else SecondaryText, onLike, count = engagementCountLabel(likeCount))
        ActionPill(Icons.Outlined.ChatBubbleOutline, "Comment", SecondaryText, onComment,
            count = engagementCountLabel(commentCount))
        ActionPill(if (zapped) Icons.Filled.Bolt else Icons.Outlined.Bolt, "Zap",
            if (zapped || zapSats > 0) Color(0xFFF5A623) else SecondaryText, onZap,
            count = zapSats.takeIf { it > 0 }?.let { formatCount(it) })
        ActionPill(Icons.Outlined.BorderColor, "Highlight",
            if (highlighting) colors.primary else SecondaryText, onHighlight)
        ActionPill(Icons.Outlined.Share, "Share", SecondaryText, onShare)
    }
}

@Composable
private fun ActionPill(icon: ImageVector, label: String, tint: Color, onClick: () -> Unit, count: String? = null) {
    Row(
        verticalAlignment = Alignment.CenterVertically,
        horizontalArrangement = Arrangement.spacedBy(5.dp, Alignment.CenterHorizontally),
        modifier = Modifier
            .defaultMinSize(minWidth = 44.dp, minHeight = 36.dp)
            .clip(RoundedCornerShape(50))
            .background(SecondaryText.copy(alpha = 0.1f))
            .clickable(onClick = onClick)
            .padding(horizontal = if (count == null) 0.dp else 12.dp),
    ) {
        Icon(icon, contentDescription = if (count == null) label else "$label, $count", tint = tint,
            modifier = Modifier.size(18.dp))
        if (count != null) {
            Text(count, color = tint, fontSize = 13.sp, fontWeight = FontWeight.SemiBold, maxLines = 1)
        }
    }
}

/** Trim the tapped paragraph to the part worth keeping, optionally add a thought. */
@Composable
private fun HighlightDialog(
    initialPassage: String,
    onDismiss: () -> Unit,
    onPublish: (String, String) -> Unit,
) {
    val colors = LocalNostrVaultColors.current
    var passage by remember { mutableStateOf(initialPassage) }
    var comment by remember { mutableStateOf("") }
    AlertDialog(
        onDismissRequest = onDismiss,
        title = { Text("Highlight") },
        text = {
            Column(verticalArrangement = Arrangement.spacedBy(12.dp)) {
                OutlinedTextField(
                    value = passage,
                    onValueChange = { passage = it },
                    label = { Text("Delete what you don't want to keep") },
                    minLines = 3,
                    maxLines = 8,
                    modifier = Modifier.fillMaxWidth(),
                )
                OutlinedTextField(
                    value = comment,
                    onValueChange = { comment = it },
                    label = { Text("Your thoughts (optional)") },
                    maxLines = 4,
                    modifier = Modifier.fillMaxWidth(),
                )
            }
        },
        confirmButton = {
            TextButton(onClick = { onPublish(passage, comment) }, enabled = passage.isNotBlank()) {
                Text("Publish", color = if (passage.isNotBlank()) colors.primary else SecondaryText)
            }
        },
        dismissButton = { TextButton(onClick = onDismiss) { Text("Cancel") } },
    )
}

@Composable
private fun ArticleBody(
    note: FeedNote,
    author: FeedProfile?,
    onProfileClick: (String) -> Unit,
    actions: @Composable () -> Unit,
    onHighlightBlock: ((String) -> Unit)?,
    highlights: List<ArticleHighlight>,
    profiles: Map<String, FeedProfile>,
    onShowHighlights: (List<ArticleHighlight>) -> Unit,
    onCommentHighlight: (ArticleHighlight) -> Unit,
    tally: ArticleTally,
    onOpenComment: (ArticleEngagementEvent) -> Unit,
    modifier: Modifier = Modifier,
) {
    val meta = remember(note.id, note.tags) { ArticleMeta.from(note) }
    val readMinutes = remember(note.id) { ArticleMeta.readingTimeMinutes(note.content) }
    val blocks = remember(note.content) { ArticleEngagement.blocks(note.content) }
    val placed = remember(blocks, highlights) { ArticleEngagement.place(highlights, blocks) }
    val colors = LocalNostrVaultColors.current

    Column(modifier = modifier) {
        Spacer(Modifier.height(8.dp))
        meta.imageUrl?.let { url ->
            AsyncImage(
                model = url,
                contentDescription = null,
                contentScale = ContentScale.Crop,
                modifier = Modifier
                    .fillMaxWidth()
                    .height(180.dp)
                    .clip(RoundedCornerShape(12.dp)),
            )
            Spacer(Modifier.height(16.dp))
        }
        Text(
            text = meta.title,
            color = PrimaryText,
            fontSize = 24.sp,
            fontWeight = FontWeight.Bold,
            lineHeight = 30.sp,
        )
        Spacer(Modifier.height(8.dp))
        Text(
            text = buildString {
                append(author?.bestName ?: note.pubkey.take(8))
                append(" · ")
                append(DateFormat.getDateInstance(DateFormat.MEDIUM).format(meta.publishedAt))
                readMinutes?.let { append(" · $it min read") }
            },
            color = SecondaryText,
            fontSize = 13.sp,
            modifier = Modifier.clickable { onProfileClick(note.pubkey) },
        )
        meta.summary?.let {
            Spacer(Modifier.height(12.dp))
            Text(it, color = SecondaryText, fontSize = 15.sp, lineHeight = 21.sp)
        }
        Spacer(Modifier.height(16.dp))
        actions()
        Spacer(Modifier.height(20.dp))
        val bodyStyle = TextStyle(color = PrimaryText, fontSize = 16.sp, lineHeight = 24.sp)
        if (onHighlightBlock == null && placed.isEmpty()) {
            MarkdownText(
                markdown = note.content,
                style = bodyStyle,
                linkColor = colors.primary,
                modifier = Modifier.fillMaxWidth(),
            )
        } else if (onHighlightBlock == null) {
            // Block by block, so a passage other people highlighted gets a
            // soft yellow tint and a count that opens who highlighted it.
            Column(verticalArrangement = Arrangement.spacedBy(12.dp)) {
                blocks.forEachIndexed { index, block ->
                    val shown = placed[index]
                    if (shown == null) {
                        MarkdownText(markdown = block, style = bodyStyle, linkColor = colors.primary,
                            modifier = Modifier.fillMaxWidth())
                    } else {
                        Column(horizontalAlignment = Alignment.End, verticalArrangement = Arrangement.spacedBy(4.dp)) {
                            MarkdownText(
                                markdown = block,
                                style = bodyStyle,
                                linkColor = colors.primary,
                                modifier = Modifier
                                    .fillMaxWidth()
                                    .clip(RoundedCornerShape(8.dp))
                                    .background(HighlightYellow.copy(alpha = 0.16f))
                                    .padding(horizontal = 8.dp, vertical = 6.dp),
                            )
                            Row(
                                verticalAlignment = Alignment.CenterVertically,
                                horizontalArrangement = Arrangement.spacedBy(4.dp),
                                modifier = Modifier
                                    .clip(RoundedCornerShape(50))
                                    .background(HighlightYellow.copy(alpha = 0.16f))
                                    .clickable(onClickLabel = if (shown.size == 1) "1 highlight" else "${shown.size} highlights") {
                                        onShowHighlights(shown)
                                    }
                                    .padding(horizontal = 10.dp, vertical = 4.dp),
                            ) {
                                Icon(Icons.Outlined.BorderColor, contentDescription = null, tint = SecondaryText,
                                    modifier = Modifier.size(13.dp))
                                Text("${shown.size}", color = SecondaryText, fontSize = 12.sp, fontWeight = FontWeight.SemiBold)
                            }
                        }
                    }
                }
            }
        } else {
            // Highlight mode: one tappable block per paragraph, tinted so the
            // reader can see what a tap will pick up.
            Text("Tap a paragraph to highlight it", color = colors.primary, fontSize = 13.sp, fontWeight = FontWeight.Medium)
            Spacer(Modifier.height(12.dp))
            Column(verticalArrangement = Arrangement.spacedBy(10.dp)) {
                blocks.forEach { block ->
                    Text(
                        text = ArticleEngagement.plainText(block),
                        color = PrimaryText,
                        fontSize = 16.sp,
                        lineHeight = 24.sp,
                        modifier = Modifier
                            .fillMaxWidth()
                            .clip(RoundedCornerShape(8.dp))
                            .background(colors.primary.copy(alpha = 0.08f))
                            .clickable { onHighlightBlock(ArticleEngagement.plainText(block)) }
                            .padding(horizontal = 8.dp, vertical = 6.dp),
                    )
                }
            }
        }
        if (highlights.isNotEmpty()) {
            Spacer(Modifier.height(24.dp))
            HorizontalDivider(color = SecondaryText.copy(alpha = 0.2f))
            Spacer(Modifier.height(16.dp))
            Row(verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(6.dp)) {
                Icon(Icons.Outlined.BorderColor, contentDescription = null, tint = PrimaryText, modifier = Modifier.size(16.dp))
                Text("Highlights · ${highlights.size}", color = PrimaryText, fontSize = 15.sp, fontWeight = FontWeight.SemiBold)
            }
            Spacer(Modifier.height(14.dp))
            Column(verticalArrangement = Arrangement.spacedBy(16.dp)) {
                highlights.forEach { h ->
                    HighlightRow(h, profiles[h.pubkey], onComment = { onCommentHighlight(h) })
                }
            }
        }
        Spacer(Modifier.height(24.dp))
        HorizontalDivider(color = SecondaryText.copy(alpha = 0.2f))
        Spacer(Modifier.height(12.dp))
        actions()
        if (tally.commentCount > 0) {
            Spacer(Modifier.height(24.dp))
            Row(verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(6.dp)) {
                Icon(Icons.Outlined.Forum, contentDescription = null, tint = PrimaryText, modifier = Modifier.size(16.dp))
                Text("Comments · ${tally.commentCount}", color = PrimaryText, fontSize = 15.sp, fontWeight = FontWeight.SemiBold)
            }
            Spacer(Modifier.height(12.dp))
            Column(verticalArrangement = Arrangement.spacedBy(12.dp)) {
                tally.topLevelComments.forEach { comment ->
                    ArticleCommentRow(
                        comment = comment,
                        author = profiles[comment.pubkey],
                        replies = tally.replyCounts[comment.id] ?: 0,
                        onClick = { onOpenComment(comment) },
                    )
                }
            }
        }
        Spacer(Modifier.height(48.dp))
    }
}

private val HighlightYellow = Color(0xFFFFD60A)

/** One comment under an article: who, when, what. Opens as a note, where its replies are. */
@Composable
private fun ArticleCommentRow(comment: ArticleEngagementEvent, author: FeedProfile?, replies: Int, onClick: () -> Unit) {
    val colors = LocalNostrVaultColors.current
    Column(
        verticalArrangement = Arrangement.spacedBy(6.dp),
        modifier = Modifier
            .fillMaxWidth()
            .clip(RoundedCornerShape(12.dp))
            .background(SecondaryText.copy(alpha = 0.08f))
            .clickable(onClick = onClick)
            .padding(12.dp),
    ) {
        Row(verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(8.dp)) {
            AvatarImage(url = author?.pictureURL, pubkey = comment.pubkey, size = 24.dp, displayName = author?.bestName)
            Text(
                author?.bestName ?: ("npub…" + comment.pubkey.takeLast(6)),
                color = PrimaryText, fontSize = 13.sp, fontWeight = FontWeight.SemiBold, maxLines = 1,
                modifier = Modifier.weight(1f, fill = false),
            )
            Text(
                DateUtils.getRelativeTimeSpanString(
                    comment.createdAt * 1000, System.currentTimeMillis(), DateUtils.MINUTE_IN_MILLIS,
                ).toString(),
                color = SecondaryText, fontSize = 11.sp, maxLines = 1,
            )
        }
        if (comment.content.isNotBlank()) {
            Text(comment.content.trim(), color = PrimaryText, fontSize = 14.sp, lineHeight = 20.sp)
        }
        if (replies > 0) {
            Row(verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(4.dp)) {
                Icon(Icons.AutoMirrored.Outlined.Reply, contentDescription = null, tint = colors.primary,
                    modifier = Modifier.size(13.dp))
                Text(if (replies == 1) "1 reply" else "$replies replies", color = colors.primary,
                    fontSize = 12.sp, fontWeight = FontWeight.Medium)
            }
        }
    }
}

/** One person's highlight: who, the passage, their comment if any, and a reply button. */
@Composable
private fun HighlightRow(highlight: ArticleHighlight, author: FeedProfile?, onComment: () -> Unit) {
    val name = author?.bestName ?: ("npub…" + highlight.pubkey.takeLast(6))
    Column(verticalArrangement = Arrangement.spacedBy(6.dp)) {
        Row(verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(8.dp)) {
            AvatarImage(url = author?.pictureURL, pubkey = highlight.pubkey, size = 22.dp, displayName = author?.bestName)
            Text(name, color = PrimaryText, fontSize = 13.sp, fontWeight = FontWeight.SemiBold)
            Text(
                DateUtils.getRelativeTimeSpanString(
                    highlight.createdAt * 1000, System.currentTimeMillis(), DateUtils.MINUTE_IN_MILLIS,
                ).toString(),
                color = SecondaryText,
                fontSize = 11.sp,
            )
        }
        Row(modifier = Modifier.height(IntrinsicSize.Min)) {
            Box(
                Modifier
                    .width(3.dp)
                    .fillMaxHeight()
                    .clip(RoundedCornerShape(2.dp))
                    .background(HighlightYellow.copy(alpha = 0.8f)),
            )
            Spacer(Modifier.width(8.dp))
            Text(
                highlight.passage,
                color = PrimaryText,
                fontSize = 14.sp,
                lineHeight = 20.sp,
                fontStyle = androidx.compose.ui.text.font.FontStyle.Italic,
            )
        }
        highlight.comment?.let {
            Text(it, color = SecondaryText, fontSize = 14.sp, lineHeight = 20.sp)
        }
        Row(
            verticalAlignment = Alignment.CenterVertically,
            horizontalArrangement = Arrangement.spacedBy(6.dp),
            modifier = Modifier
                .padding(start = 11.dp)
                .clip(RoundedCornerShape(50))
                .background(SecondaryText.copy(alpha = 0.1f))
                .clickable(onClick = onComment)
                .padding(horizontal = 10.dp, vertical = 5.dp),
        ) {
            Icon(Icons.Outlined.ChatBubbleOutline, contentDescription = null, tint = SecondaryText, modifier = Modifier.size(13.dp))
            Text("Comment", color = SecondaryText, fontSize = 12.sp, fontWeight = FontWeight.SemiBold)
        }
    }
}
