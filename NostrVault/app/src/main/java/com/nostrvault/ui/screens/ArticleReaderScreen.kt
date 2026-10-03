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
import com.nostrvault.data.model.ArticleMeta
import com.nostrvault.data.model.NIP10Thread
import com.nostrvault.relay.HavenBridge
import com.nostrvault.service.ZapSendService
import com.nostrvault.ui.components.CustomZapSheet
import com.nostrvault.ui.components.threadLink
import com.nostrvault.data.model.FeedNote
import com.nostrvault.data.model.FeedProfile
import com.nostrvault.service.FeedService
import com.nostrvault.service.NostrService
import com.nostrvault.ui.theme.*
import dagger.hilt.android.lifecycle.HiltViewModel
import dev.jeziellago.compose.markdowntext.MarkdownText
import kotlinx.coroutines.flow.MutableSharedFlow
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.SharedFlow
import kotlinx.coroutines.launch
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.asStateFlow
import java.text.DateFormat
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
                    _message.emit("Zapped ⚡$amountSats sats")
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
            } else {
                _message.emit("Highlight not signed")
            }
        }
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
        when {
            current != null -> ArticleBody(
                note = current,
                author = profiles[current.pubkey],
                onProfileClick = onProfileClick,
                actions = {
                    ArticleActionBar(
                        liked = current.id in liked,
                        zapped = zapped,
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

    val target = note
    if (showZapSheet && target != null) {
        CustomZapSheet(
            sheetState = zapSheetState,
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
            if (liked) Color(0xFFE5484D) else SecondaryText, onLike)
        ActionPill(Icons.Outlined.ChatBubbleOutline, "Comment", SecondaryText, onComment)
        ActionPill(if (zapped) Icons.Filled.Bolt else Icons.Outlined.Bolt, "Zap",
            if (zapped) Color(0xFFF5A623) else SecondaryText, onZap)
        ActionPill(Icons.Outlined.BorderColor, "Highlight",
            if (highlighting) colors.primary else SecondaryText, onHighlight)
        ActionPill(Icons.Outlined.Share, "Share", SecondaryText, onShare)
    }
}

@Composable
private fun ActionPill(icon: ImageVector, label: String, tint: Color, onClick: () -> Unit) {
    Box(
        contentAlignment = Alignment.Center,
        modifier = Modifier
            .size(width = 44.dp, height = 36.dp)
            .clip(RoundedCornerShape(50))
            .background(SecondaryText.copy(alpha = 0.1f))
            .clickable(onClick = onClick),
    ) {
        Icon(icon, contentDescription = label, tint = tint, modifier = Modifier.size(18.dp))
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
    modifier: Modifier = Modifier,
) {
    val meta = remember(note.id, note.tags) { ArticleMeta.from(note) }
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
        if (onHighlightBlock == null) {
            MarkdownText(
                markdown = note.content,
                style = TextStyle(color = PrimaryText, fontSize = 16.sp, lineHeight = 24.sp),
                linkColor = colors.primary,
                modifier = Modifier.fillMaxWidth(),
            )
        } else {
            // Highlight mode: one tappable block per paragraph, tinted so the
            // reader can see what a tap will pick up.
            Text("Tap a paragraph to highlight it", color = colors.primary, fontSize = 13.sp, fontWeight = FontWeight.Medium)
            Spacer(Modifier.height(12.dp))
            val blocks = remember(note.content) { ArticleEngagement.blocks(note.content) }
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
        Spacer(Modifier.height(24.dp))
        HorizontalDivider(color = SecondaryText.copy(alpha = 0.2f))
        Spacer(Modifier.height(12.dp))
        actions()
        Spacer(Modifier.height(48.dp))
    }
}
