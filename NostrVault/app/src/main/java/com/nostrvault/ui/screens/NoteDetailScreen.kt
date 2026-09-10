package com.nostrvault.ui.screens

import androidx.compose.animation.animateContentSize
import androidx.compose.animation.core.spring
import androidx.compose.foundation.ExperimentalFoundationApi
import androidx.compose.foundation.background
import androidx.compose.foundation.border
import androidx.compose.foundation.clickable
import androidx.compose.foundation.combinedClickable
import androidx.compose.foundation.layout.*
import androidx.compose.foundation.layout.IntrinsicSize
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.items
import androidx.compose.foundation.lazy.rememberLazyListState
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material3.*
import androidx.compose.runtime.*
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.layout.ContentScale
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import androidx.hilt.navigation.compose.hiltViewModel
import androidx.lifecycle.SavedStateHandle
import androidx.lifecycle.ViewModel
import androidx.lifecycle.viewModelScope
import coil.compose.AsyncImage
import com.nostrvault.data.model.*
import com.nostrvault.service.FeedService
import com.nostrvault.service.NostrService
import com.nostrvault.ui.components.*
import com.nostrvault.ui.theme.*
import dagger.hilt.android.lifecycle.HiltViewModel
import kotlinx.coroutines.flow.*
import kotlinx.coroutines.launch
import java.text.SimpleDateFormat
import java.util.*
import javax.inject.Inject

/**
 * Thread view for a single note with parent chain, nested replies,
 * tap-to-focus navigation, and depth-based collapsing.
 * Port of NoteDetailView.swift.
 */

@HiltViewModel
class NoteDetailViewModel @Inject constructor(
    savedStateHandle: SavedStateHandle,
    private val nostrService: NostrService,
    private val feedService: FeedService,
) : ViewModel() {

    val noteId: String = savedStateHandle["noteId"] ?: ""

    private val _note = MutableStateFlow<FeedNote?>(null)
    val note: StateFlow<FeedNote?> = _note.asStateFlow()

    private val _parentNotes = MutableStateFlow<List<FeedNote>>(emptyList())
    val parentNotes: StateFlow<List<FeedNote>> = _parentNotes.asStateFlow()

    /** All replies in the thread (flat list used to build the tree). */
    private val _allReplies = MutableStateFlow<List<FeedNote>>(emptyList())
    val allReplies: StateFlow<List<FeedNote>> = _allReplies.asStateFlow()

    val profiles: StateFlow<Map<String, FeedProfile>> = nostrService.profiles
    val noteStats: StateFlow<Map<String, NoteStats>> = feedService.noteStats
    val likedEventIds: StateFlow<Set<String>> = feedService.likedEventIds

    private val _isLoading = MutableStateFlow(true)
    val isLoading: StateFlow<Boolean> = _isLoading.asStateFlow()

    private val _isCompact = MutableStateFlow(false)
    val isCompact: StateFlow<Boolean> = _isCompact.asStateFlow()

    // Engagement details for the focused (hero) note
    private val _engagementDetails = MutableStateFlow<EngagementDetails?>(null)
    val engagementDetails: StateFlow<EngagementDetails?> = _engagementDetails.asStateFlow()

    // Thread-wide engagement stats
    private val _expandedEngagement = MutableStateFlow(false)
    val expandedEngagement: StateFlow<Boolean> = _expandedEngagement.asStateFlow()

    private val _perNoteEngagement = MutableStateFlow<Map<String, EngagementDetails>>(emptyMap())
    val perNoteEngagement: StateFlow<Map<String, EngagementDetails>> = _perNoteEngagement.asStateFlow()

    init {
        loadNoteThread()
    }

    private fun loadNoteThread() {
        viewModelScope.launch {
            _isLoading.value = true

            val foundNote = feedService.findNote(noteId)
            _note.value = foundNote

            if (foundNote != null) {
                // Initial ancestor chain from the in-memory cache.
                _parentNotes.value = buildAncestorChain(foundNote, emptyList())

                // Fetch the whole thread by NIP-10 root so a mid-thread reply
                // opens with its siblings + ancestors (matching iOS), not just
                // the opened note's direct replies. Ancestor e-tags (minus
                // mentions) are fetched by id to fill any gaps in the chain.
                val rootId = foundNote.threadRootId
                val ancestorIds = foundNote.tags
                    .filter { it.size >= 2 && it[0] == "e" && (it.size < 4 || it[3] != "mention") }
                    .map { it[1] }
                nostrService.fetchThread(rootId, noteId, ancestorIds) { threadNotes ->
                    _allReplies.value = threadNotes.sortedBy { it.createdAt }
                    // Rebuild the chain now that fetched notes may fill gaps.
                    _parentNotes.value = buildAncestorChain(foundNote, threadNotes)
                }

                val pubkeys = (_parentNotes.value.map { it.pubkey } + foundNote.pubkey).distinct()
                nostrService.fetchMissingProfiles(pubkeys)

                // Fetch engagement details for hero note
                fetchEngagement(noteId)
            }

            _isLoading.value = false
        }
    }

    /**
     * Walk parentEventId upward, resolving each ancestor from the in-memory
     * cache first, then from [extra] (e.g. notes just fetched from the
     * network). Cycle-guarded; returns the chain oldest-first.
     */
    private fun buildAncestorChain(note: FeedNote, extra: List<FeedNote>): List<FeedNote> {
        val lookup = extra.associateBy { it.id }
        val chain = mutableListOf<FeedNote>()
        val seen = HashSet<String>()
        var currentId = note.parentEventId
        while (currentId != null && seen.add(currentId)) {
            val parent = feedService.findNote(currentId) ?: lookup[currentId]
            if (parent != null) {
                chain.add(0, parent)
                currentId = parent.parentEventId
            } else {
                break
            }
        }
        return chain
    }

    fun fetchEngagement(noteId: String) {
        feedService.fetchEngagementDetails(noteId) { details ->
            _engagementDetails.value = details
        }
    }

    fun toggleCompact() {
        _isCompact.value = !_isCompact.value
    }

    fun likeNote(noteId: String) {
        viewModelScope.launch { feedService.likeNote(noteId) }
    }

    fun reactToNote(noteId: String, emoji: String) {
        viewModelScope.launch { feedService.likeNote(noteId, emoji) }
    }

    fun repostNote(noteId: String) {
        viewModelScope.launch { feedService.repostNote(noteId) }
    }

    // Moderation
    fun isOwnNote(pubkey: String): Boolean = pubkey == nostrService.activeHexPubkey

    fun followUser(pubkey: String) {
        viewModelScope.launch { feedService.followUser(pubkey) }
    }

    fun unfollowUser(pubkey: String) {
        viewModelScope.launch { feedService.unfollowUser(pubkey) }
    }

    fun isFollowing(pubkey: String): Boolean = feedService.isFollowing(pubkey)

    fun blockUser(pubkey: String) {
        viewModelScope.launch { feedService.blockUser(pubkey) }
    }

    fun deleteNote(noteId: String) {
        viewModelScope.launch {
            nostrService.deleteNote(noteId)
            feedService.removeNote(noteId)
        }
    }

    fun reportNote(noteId: String, pubkey: String, reason: String) {
        viewModelScope.launch { nostrService.reportEvent(noteId, pubkey, reason) }
    }

    // Thread-wide stats
    fun toggleExpandedEngagement() {
        _expandedEngagement.value = !_expandedEngagement.value
        if (_expandedEngagement.value && _perNoteEngagement.value.isEmpty()) {
            fetchThreadEngagement()
        }
    }

    private fun fetchThreadEngagement() {
        val allIds = buildList {
            addAll(_parentNotes.value.map { it.id })
            _note.value?.id?.let { add(it) }
            addAll(_allReplies.value.map { it.id })
        }
        if (allIds.isEmpty()) return
        feedService.fetchThreadEngagement(allIds) { result ->
            _perNoteEngagement.value = result
        }
    }

    fun profileFor(pubkey: String): FeedProfile? = profiles.value[pubkey]
    fun statsFor(noteId: String): NoteStats? = noteStats.value[noteId]
    fun isLiked(noteId: String): Boolean = likedEventIds.value.contains(noteId)

    /** Get direct child replies for a given note ID. */
    fun childRepliesFor(parentId: String): List<FeedNote> =
        _allReplies.value.filter { it.parentEventId == parentId }
}

// ── Screen ──────────────────────────────────────────────────────

@OptIn(ExperimentalMaterial3Api::class, ExperimentalFoundationApi::class)
@Composable
fun NoteDetailScreen(
    noteId: String,
    onProfileClick: (String) -> Unit,
    onNoteClick: (String) -> Unit,
    onReply: (String) -> Unit,
    onQuote: (String) -> Unit,
    onBack: () -> Unit,
    viewModel: NoteDetailViewModel = hiltViewModel(),
) {
    val note by viewModel.note.collectAsState()
    val parentNotes by viewModel.parentNotes.collectAsState()
    val allReplies by viewModel.allReplies.collectAsState()
    val isLoading by viewModel.isLoading.collectAsState()
    val isCompact by viewModel.isCompact.collectAsState()
    val engagementDetails by viewModel.engagementDetails.collectAsState()
    val expandedEngagement by viewModel.expandedEngagement.collectAsState()
    val perNoteEngagement by viewModel.perNoteEngagement.collectAsState()
    val profiles by viewModel.profiles.collectAsState()
    val colors = LocalNostrVaultColors.current
    val listState = rememberLazyListState()
    val scope = rememberCoroutineScope()

    // The currently focused note (hero). Starts as the original note,
    // tapping a parent or reply refocuses the thread around it.
    var focusedNoteId by remember { mutableStateOf(noteId) }

    // Engagement sheet states
    var showReactorsSheet by remember { mutableStateOf(false) }
    var showZappersSheet by remember { mutableStateOf(false) }
    var showRepostersSheet by remember { mutableStateOf(false) }

    // Emoji picker state
    var showEmojiPicker by remember { mutableStateOf(false) }

    // Delete confirmation
    var showDeleteDialog by remember { mutableStateOf(false) }
    var showBlockDialog by remember { mutableStateOf(false) }

    // Re-fetch engagement and replies when focus changes
    LaunchedEffect(focusedNoteId) {
        viewModel.fetchEngagement(focusedNoteId)
    }

    // Derive focused note, parents, and direct replies from focusedNoteId
    val focusedNote = remember(focusedNoteId, note, allReplies) {
        if (focusedNoteId == noteId) note
        else allReplies.find { it.id == focusedNoteId }
            ?: parentNotes.find { it.id == focusedNoteId }
            ?: note
    }

    val dynamicParents = remember(focusedNoteId, parentNotes, allReplies, note) {
        if (focusedNoteId == noteId) {
            parentNotes
        } else {
            // Build parent chain up to focusedNoteId
            val chain = mutableListOf<FeedNote>()
            val allNotes = parentNotes + listOfNotNull(note) + allReplies
            var currentId: String? = allNotes.find { it.id == focusedNoteId }?.parentEventId
            while (currentId != null) {
                val parent = allNotes.find { it.id == currentId }
                if (parent != null) {
                    chain.add(0, parent)
                    currentId = parent.parentEventId
                } else break
            }
            chain
        }
    }

    val directReplies = remember(focusedNoteId, allReplies, note) {
        val heroId = focusedNote?.id ?: noteId
        allReplies.filter { it.parentEventId == heroId }.sortedBy { it.createdAt }
    }

    // Auto-scroll to hero note when focus changes or loading completes.
    // This replaces both the initial scroll and tap-to-focus scroll.
    LaunchedEffect(focusedNoteId, isLoading) {
        if (!isLoading && note != null) {
            // Allow layout to settle after recomposition
            kotlinx.coroutines.delay(250)
            val heroIndex = dynamicParents.size
            if (heroIndex in 0 until listState.layoutInfo.totalItemsCount) {
                listState.animateScrollToItem(heroIndex, scrollOffset = -100)
            }
        }
    }

    fun scrollToNote(targetId: String) {
        focusedNoteId = targetId
        // LaunchedEffect(focusedNoteId) handles the actual scroll after recomposition
    }

    // Delete confirmation dialog
    if (showDeleteDialog && focusedNote != null) {
        AlertDialog(
            onDismissRequest = { showDeleteDialog = false },
            title = { Text("Delete Post", color = PrimaryText) },
            text = { Text("Request deletion of this post? Not all relays honor NIP-09 deletion requests.", color = SecondaryText) },
            confirmButton = {
                TextButton(
                    onClick = {
                        viewModel.deleteNote(focusedNote!!.id)
                        showDeleteDialog = false
                        onBack()
                    },
                    colors = ButtonDefaults.textButtonColors(contentColor = LikeRed),
                ) { Text("Delete") }
            },
            dismissButton = {
                TextButton(onClick = { showDeleteDialog = false }) { Text("Cancel", color = SecondaryText) }
            },
            containerColor = SecondaryGroupedBg,
        )
    }

    // Block confirmation dialog
    if (showBlockDialog && focusedNote != null) {
        AlertDialog(
            onDismissRequest = { showBlockDialog = false },
            title = { Text("Block User", color = PrimaryText) },
            text = { Text("Block this user? Their posts will be hidden from your feed.", color = SecondaryText) },
            confirmButton = {
                TextButton(
                    onClick = {
                        viewModel.blockUser(focusedNote!!.pubkey)
                        showBlockDialog = false
                        onBack()
                    },
                    colors = ButtonDefaults.textButtonColors(contentColor = LikeRed),
                ) { Text("Block") }
            },
            dismissButton = {
                TextButton(onClick = { showBlockDialog = false }) { Text("Cancel", color = SecondaryText) }
            },
            containerColor = SecondaryGroupedBg,
        )
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
                // Leading pill: back button
                GlassPill {
                    IconButton(onClick = onBack, modifier = Modifier.size(40.dp)) {
                        Icon(NostrVaultIcons.Back, "Back", tint = PrimaryText, modifier = Modifier.size(25.dp))
                    }
                }

                Spacer(Modifier.weight(1f))

                // Trailing pill: compact toggle + stats + reply + broadcast
                GlassPill {
                    // Compact view toggle
                    IconButton(
                        onClick = viewModel::toggleCompact,
                        modifier = Modifier.size(40.dp),
                    ) {
                        Icon(
                            imageVector = if (isCompact) NostrVaultIcons.CompactView else NostrVaultIcons.ExpandedView,
                            contentDescription = if (isCompact) "Expanded view" else "Compact view",
                            tint = if (isCompact) colors.primary else SecondaryText,
                            modifier = Modifier.size(25.dp),
                        )
                    }
                    // Thread stats toggle
                    IconButton(
                        onClick = viewModel::toggleExpandedEngagement,
                        modifier = Modifier.size(40.dp),
                    ) {
                        Icon(
                            NostrVaultIcons.BarChart,
                            "Thread Stats",
                            tint = if (expandedEngagement) colors.primary else SecondaryText,
                            modifier = Modifier.size(25.dp),
                        )
                    }
                    // Reply
                    IconButton(onClick = { focusedNote?.let { onReply(it.id) } }, modifier = Modifier.size(40.dp)) {
                        Icon(NostrVaultIcons.Reply, "Reply", tint = SecondaryText, modifier = Modifier.size(25.dp))
                    }
                    // Broadcast
                    IconButton(onClick = { /* broadcast */ }, modifier = Modifier.size(40.dp)) {
                        Icon(NostrVaultIcons.Relay, "Broadcast", tint = SecondaryText, modifier = Modifier.size(25.dp))
                    }
                }
            }
        },
    ) { padding ->
        if (isLoading) {
            Box(
                contentAlignment = Alignment.Center,
                modifier = Modifier
                    .fillMaxSize()
                    .padding(padding),
            ) {
                CircularProgressIndicator(color = colors.primary)
            }
        } else if (focusedNote == null) {
            Box(
                contentAlignment = Alignment.Center,
                modifier = Modifier
                    .fillMaxSize()
                    .padding(padding),
            ) {
                Text("Note not found", color = SecondaryText, fontSize = 16.sp)
            }
        } else {
            LazyColumn(
                state = listState,
                contentPadding = padding,
                modifier = Modifier.fillMaxSize(),
            ) {
                // ── Parent chain ────────────────────────────────
                items(dynamicParents, key = { it.id }) { parent ->
                    if (isCompact) {
                        CompactParentRow(
                            note = parent,
                            profile = viewModel.profileFor(parent.pubkey),
                            isFocused = parent.id == focusedNoteId,
                            themeColor = colors.primary,
                            onClick = { scrollToNote(parent.id) },
                        )
                    } else {
                        NoteCard(
                            note = parent,
                            profile = viewModel.profileFor(parent.pubkey),
                            stats = viewModel.statsFor(parent.id),
                            isLiked = viewModel.isLiked(parent.id),
                            isFocused = parent.id == focusedNoteId,
                            parentIsNext = true,
                            onNoteClick = { scrollToNote(parent.id) },
                            onProfileClick = onProfileClick,
                            onLike = viewModel::likeNote,
                        )
                    }
                    // Thread connector line
                    ThreadConnectorLine(color = colors.primary)
                }

                // ── Hero note ───────────────────────────────────
                item(key = "hero_${focusedNote!!.id}") {
                    HeroNoteCard(
                        note = focusedNote!!,
                        profile = viewModel.profileFor(focusedNote!!.pubkey),
                        stats = viewModel.statsFor(focusedNote!!.id),
                        isLiked = viewModel.isLiked(focusedNote!!.id),
                        isOwnNote = viewModel.isOwnNote(focusedNote!!.pubkey),
                        isFollowing = viewModel.isFollowing(focusedNote!!.pubkey),
                        themeColor = colors.primary,
                        onProfileClick = onProfileClick,
                        onLike = { viewModel.likeNote(focusedNote!!.id) },
                        onLongPressLike = { showEmojiPicker = true },
                        onRepost = { viewModel.repostNote(focusedNote!!.id) },
                        onQuote = { onQuote(focusedNote!!.id) },
                        onReply = { onReply(focusedNote!!.id) },
                        onFollow = { viewModel.followUser(focusedNote!!.pubkey) },
                        onUnfollow = { viewModel.unfollowUser(focusedNote!!.pubkey) },
                        onBlock = { showBlockDialog = true },
                        onDelete = { showDeleteDialog = true },
                        onReport = { viewModel.reportNote(focusedNote!!.id, focusedNote!!.pubkey, "spam") },
                        onReactionsClick = { showReactorsSheet = true },
                        onRepostsClick = { showRepostersSheet = true },
                        onZapsClick = { showZappersSheet = true },
                    )
                }

                // ── Replies header ──────────────────────────────
                if (directReplies.isNotEmpty()) {
                    item {
                        Text(
                            text = "${directReplies.size} ${if (directReplies.size == 1) "Reply" else "Replies"}",
                            color = SecondaryText,
                            fontSize = 14.sp,
                            fontWeight = FontWeight.SemiBold,
                            modifier = Modifier.padding(horizontal = 16.dp, vertical = 12.dp),
                        )
                    }
                }

                // ── Threaded replies ────────────────────────────
                items(directReplies, key = { it.id }) { reply ->
                    ThreadedReplyNode(
                        reply = reply,
                        depth = 1,
                        isCompact = isCompact,
                        focusedNoteId = focusedNoteId,
                        themeColor = colors.primary,
                        viewModel = viewModel,
                        expandedEngagement = expandedEngagement,
                        perNoteEngagement = perNoteEngagement,
                        profiles = profiles,
                        onProfileClick = onProfileClick,
                        onNoteClick = onNoteClick,
                        onFocus = { id -> scrollToNote(id) },
                    )
                }

                // Bottom spacer
                item { Spacer(Modifier.height(32.dp)) }
            }
        }
    }

    // ── Bottom sheets ────────────────────────────────────────────
    if (showReactorsSheet) {
        ReactorsSheet(
            reactions = engagementDetails?.reactions ?: emptyList(),
            profiles = profiles,
            onProfileClick = onProfileClick,
            onDismiss = { showReactorsSheet = false },
        )
    }
    if (showZappersSheet) {
        ZappersSheet(
            zaps = engagementDetails?.zaps ?: emptyList(),
            profiles = profiles,
            onProfileClick = onProfileClick,
            onDismiss = { showZappersSheet = false },
        )
    }
    if (showRepostersSheet) {
        RepostersSheet(
            reposts = engagementDetails?.reposts ?: emptyList(),
            profiles = profiles,
            onProfileClick = onProfileClick,
            onDismiss = { showRepostersSheet = false },
        )
    }
    if (showEmojiPicker && focusedNote != null) {
        val emojiSheetState = rememberModalBottomSheetState(skipPartiallyExpanded = true)
        EmojiPickerSheet(
            sheetState = emojiSheetState,
            onDismiss = { showEmojiPicker = false },
            onSelectEmoji = { emoji ->
                viewModel.reactToNote(focusedNote!!.id, emoji)
                showEmojiPicker = false
            },
        )
    }
}

// ── Thread connector line ───────────────────────────────────────

@Composable
private fun ThreadConnectorLine(color: androidx.compose.ui.graphics.Color) {
    Box(
        modifier = Modifier
            .padding(start = 36.dp)
            .width(1.5.dp)
            .height(12.dp)
            .background(color.copy(alpha = 0.25f)),
    )
}

// ── Compact parent/reply row ─────────────────────────────────────
// Matches iOS compactParentNoteView / compactReplyView: 28dp avatar,
// name · timestamp header, 1–2 line content, OLED-aware focus highlight,
// optional reply count badge.

@Composable
private fun CompactParentRow(
    note: FeedNote,
    profile: FeedProfile?,
    isFocused: Boolean,
    themeColor: androidx.compose.ui.graphics.Color,
    onClick: () -> Unit,
    childReplyCount: Int = 0,
) {
    val isOled = LocalOledMode.current

    Row(
        verticalAlignment = Alignment.Top,
        modifier = Modifier
            .fillMaxWidth()
            .clickable(onClick = onClick)
            .background(
                if (isFocused) themeColor.copy(alpha = if (isOled) 0.08f else 0.12f)
                else SecondaryGroupedBg,
                RoundedCornerShape(10.dp),
            )
            .border(
                width = if (isFocused) 1.5.dp else if (isOled) 1.dp else 0.5.dp,
                color = if (isFocused) themeColor.copy(alpha = if (isOled) 0.6f else 0.4f)
                        else themeColor.copy(alpha = if (isOled) 0.30f else 0.15f),
                shape = RoundedCornerShape(10.dp),
            )
            .padding(10.dp),
    ) {
        AvatarImage(
            url = profile?.pictureURL,
            pubkey = note.pubkey,
            size = 28.dp,
            displayName = profile?.bestName,
        )
        Spacer(Modifier.width(8.dp))
        Column(modifier = Modifier.weight(1f)) {
            // Header: name · timestamp  (reply count badge on trailing edge)
            Row(verticalAlignment = Alignment.CenterVertically) {
                Text(
                    text = profile?.bestName ?: note.pubkey.take(8) + "...",
                    color = PrimaryText.copy(alpha = if (isOled) 0.85f else 0.9f),
                    fontSize = 12.sp,
                    fontWeight = FontWeight.SemiBold,
                    maxLines = 1,
                    overflow = TextOverflow.Ellipsis,
                    modifier = Modifier.weight(1f, fill = false),
                )
                Spacer(Modifier.width(4.dp))
                Text(
                    text = "· ${formatTimestamp(note.createdAt.time / 1000)}",
                    color = SecondaryText.copy(alpha = if (isOled) 0.7f else 0.8f),
                    fontSize = 10.sp,
                )
                Spacer(Modifier.weight(1f))
                // Reply count badge (matches iOS text.bubble + count)
                if (childReplyCount > 0) {
                    Row(
                        verticalAlignment = Alignment.CenterVertically,
                        horizontalArrangement = Arrangement.spacedBy(3.dp),
                    ) {
                        Icon(
                            imageVector = NostrVaultIcons.Reply,
                            contentDescription = null,
                            tint = SecondaryText.copy(alpha = if (isOled) 0.5f else 0.6f),
                            modifier = Modifier.size(9.dp),
                        )
                        Text(
                            text = "$childReplyCount",
                            color = SecondaryText.copy(alpha = if (isOled) 0.5f else 0.6f),
                            fontSize = 9.sp,
                            fontWeight = FontWeight.SemiBold,
                        )
                    }
                }
            }
            // Content (2 lines in compact to match iOS)
            if (note.content.isNotBlank()) {
                Spacer(Modifier.height(2.dp))
                Text(
                    text = note.content,
                    color = PrimaryText.copy(alpha = if (isOled) 0.7f else 0.75f),
                    fontSize = 12.sp,
                    maxLines = 2,
                    lineHeight = 16.sp,
                    overflow = TextOverflow.Ellipsis,
                )
            }
        }
    }
}

// ── Threaded reply node (recursive) ─────────────────────────────
// Matches iOS ThreadedReplyNode: recursive tree rendering with depth-based
// collapsing, compact/full modes, focus highlight, and thread connector lines.

private const val MAX_INDENT_DEPTH = 5
private const val COLLAPSE_DEPTH = 3

@Composable
private fun ThreadedReplyNode(
    reply: FeedNote,
    depth: Int,
    isCompact: Boolean,
    focusedNoteId: String,
    themeColor: androidx.compose.ui.graphics.Color,
    viewModel: NoteDetailViewModel,
    expandedEngagement: Boolean,
    perNoteEngagement: Map<String, EngagementDetails>,
    profiles: Map<String, FeedProfile>,
    onProfileClick: (String) -> Unit,
    onNoteClick: (String) -> Unit,
    onFocus: (String) -> Unit,
) {
    val childReplies = remember(reply.id) { viewModel.childRepliesFor(reply.id) }
    val isFocusedReply = reply.id == focusedNoteId

    Column(
        modifier = Modifier.animateContentSize(animationSpec = spring()),
    ) {
        // The reply itself
        if (isCompact) {
            val indentDp = (minOf(depth - 1, MAX_INDENT_DEPTH) * 16).dp
            CompactParentRow(
                note = reply,
                profile = viewModel.profileFor(reply.pubkey),
                isFocused = isFocusedReply,
                themeColor = themeColor,
                onClick = { onFocus(reply.id) },
                childReplyCount = childReplies.size,
            )
            // Compact mode: show nested replies without connector lines (iOS parity)
            if (childReplies.isNotEmpty()) {
                Column(modifier = Modifier.padding(start = indentDp)) {
                    Spacer(Modifier.height(6.dp))
                    for (child in childReplies) {
                        ThreadedReplyNode(
                            reply = child,
                            depth = depth + 1,
                            isCompact = true,
                            focusedNoteId = focusedNoteId,
                            themeColor = themeColor,
                            viewModel = viewModel,
                            expandedEngagement = expandedEngagement,
                            perNoteEngagement = perNoteEngagement,
                            profiles = profiles,
                            onProfileClick = onProfileClick,
                            onNoteClick = onNoteClick,
                            onFocus = onFocus,
                        )
                        Spacer(Modifier.height(6.dp))
                    }
                }
            }
        } else {
            NoteCard(
                note = reply,
                profile = viewModel.profileFor(reply.pubkey),
                stats = viewModel.statsFor(reply.id),
                isLiked = viewModel.isLiked(reply.id),
                isFocused = isFocusedReply,
                onNoteClick = { onFocus(reply.id) },
                onProfileClick = onProfileClick,
                onLike = viewModel::likeNote,
            )

            // Per-note engagement row when thread stats are expanded
            if (expandedEngagement) {
                val noteEngagement = perNoteEngagement[reply.id]
                if (noteEngagement != null) {
                    val reactionCount = noteEngagement.reactions.size
                    val zapCount = noteEngagement.zaps.size
                    val repostCount = noteEngagement.reposts.size
                    if (reactionCount > 0 || zapCount > 0 || repostCount > 0) {
                        Row(
                            horizontalArrangement = Arrangement.spacedBy(12.dp),
                            modifier = Modifier.padding(start = 50.dp, top = 2.dp, bottom = 4.dp),
                        ) {
                            if (reactionCount > 0) {
                                Text(
                                    text = "\u2764\uFE0F $reactionCount",
                                    color = SecondaryText,
                                    fontSize = 12.sp,
                                )
                            }
                            if (zapCount > 0) {
                                Text(
                                    text = "\u26A1 $zapCount",
                                    color = SecondaryText,
                                    fontSize = 12.sp,
                                )
                            }
                            if (repostCount > 0) {
                                Text(
                                    text = "\uD83D\uDD01 $repostCount",
                                    color = SecondaryText,
                                    fontSize = 12.sp,
                                )
                            }
                        }
                    }
                }
            }

            // Child replies
            if (childReplies.isNotEmpty()) {
                if (depth >= COLLAPSE_DEPTH) {
                    // Collapse deep threads — matches iOS "Show X more replies" pill
                    Row(
                        verticalAlignment = Alignment.CenterVertically,
                        modifier = Modifier
                            .padding(start = 16.dp, top = 4.dp, bottom = 4.dp)
                            .clickable { onFocus(reply.id) }
                            .background(themeColor.copy(alpha = 0.1f), RoundedCornerShape(8.dp))
                            .padding(vertical = 6.dp, horizontal = 12.dp),
                    ) {
                        Icon(
                            imageVector = NostrVaultIcons.Navigate,
                            contentDescription = null,
                            tint = themeColor,
                            modifier = Modifier.size(11.dp),
                        )
                        Spacer(Modifier.width(6.dp))
                        Text(
                            text = "Show ${childReplies.size} more ${if (childReplies.size == 1) "reply" else "replies"}",
                            color = themeColor,
                            fontSize = 12.sp,
                            fontWeight = FontWeight.Bold,
                        )
                    }
                } else {
                    // Render children with connector line (matches iOS HStack + Rectangle)
                    Row(
                        modifier = Modifier
                            .padding(start = 8.dp)
                            .height(IntrinsicSize.Min),
                    ) {
                        // Vertical connector line
                        Box(
                            modifier = Modifier
                                .width(1.5.dp)
                                .fillMaxHeight()
                                .padding(vertical = 2.dp)
                                .background(themeColor.copy(alpha = 0.25f)),
                        )
                        Spacer(Modifier.width(6.dp))
                        Column(verticalArrangement = Arrangement.spacedBy(8.dp)) {
                            for (child in childReplies) {
                                ThreadedReplyNode(
                                    reply = child,
                                    depth = depth + 1,
                                    isCompact = false,
                                    focusedNoteId = focusedNoteId,
                                    themeColor = themeColor,
                                    viewModel = viewModel,
                                    expandedEngagement = expandedEngagement,
                                    perNoteEngagement = perNoteEngagement,
                                    profiles = profiles,
                                    onProfileClick = onProfileClick,
                                    onNoteClick = onNoteClick,
                                    onFocus = onFocus,
                                )
                            }
                        }
                    }
                }
            }
        }
    }
}

// ── Hero note card ──────────────────────────────────────────────

@OptIn(ExperimentalFoundationApi::class)
@Composable
private fun HeroNoteCard(
    note: FeedNote,
    profile: FeedProfile?,
    stats: NoteStats?,
    isLiked: Boolean,
    isOwnNote: Boolean,
    isFollowing: Boolean,
    themeColor: androidx.compose.ui.graphics.Color,
    onProfileClick: (String) -> Unit,
    onLike: () -> Unit,
    onLongPressLike: () -> Unit,
    onRepost: () -> Unit,
    onQuote: () -> Unit,
    onReply: () -> Unit,
    onFollow: () -> Unit,
    onUnfollow: () -> Unit,
    onBlock: () -> Unit,
    onDelete: () -> Unit,
    onReport: () -> Unit,
    onReactionsClick: () -> Unit,
    onRepostsClick: () -> Unit,
    onZapsClick: () -> Unit,
) {
    val dateFormat = remember { SimpleDateFormat("MMM d, yyyy 'at' h:mm a", Locale.getDefault()) }
    var showMoreMenu by remember { mutableStateOf(false) }
    var showRepostMenu by remember { mutableStateOf(false) }

    Surface(
        color = WindowBackground,
        shape = RoundedCornerShape(12.dp),
        border = androidx.compose.foundation.BorderStroke(1.dp, themeColor.copy(alpha = 0.3f)),
        shadowElevation = 2.dp,
        modifier = Modifier
            .fillMaxWidth()
            .padding(horizontal = 8.dp, vertical = 4.dp),
    ) {
        Column(modifier = Modifier.padding(16.dp)) {
            // Author header with more menu
            Row(
                verticalAlignment = Alignment.CenterVertically,
                modifier = Modifier.fillMaxWidth(),
            ) {
                Row(
                    verticalAlignment = Alignment.CenterVertically,
                    modifier = Modifier
                        .weight(1f)
                        .clickable { onProfileClick(note.pubkey) },
                ) {
                    AsyncImage(
                        model = profile?.pictureURL,
                        contentDescription = null,
                        contentScale = ContentScale.Crop,
                        modifier = Modifier
                            .size(48.dp)
                            .clip(CircleShape),
                    )
                    Spacer(Modifier.width(12.dp))
                    Column {
                        Text(
                            text = profile?.bestName ?: note.pubkey.take(8) + "...",
                            color = PrimaryText,
                            fontSize = 16.sp,
                            fontWeight = FontWeight.SemiBold,
                        )
                        profile?.nip05?.let {
                            Text(text = it, color = SecondaryText, fontSize = 13.sp)
                        }
                    }
                }

                // More menu button
                Box {
                    IconButton(onClick = { showMoreMenu = true }) {
                        Icon(NostrVaultIcons.More, "More", tint = SecondaryText)
                    }
                    DropdownMenu(
                        expanded = showMoreMenu,
                        onDismissRequest = { showMoreMenu = false },
                    ) {
                        if (isOwnNote) {
                            DropdownMenuItem(
                                text = { Text("Delete Post", color = LikeRed) },
                                onClick = { showMoreMenu = false; onDelete() },
                                leadingIcon = { Icon(NostrVaultIcons.Delete, null, tint = LikeRed) },
                            )
                        } else {
                            if (isFollowing) {
                                DropdownMenuItem(
                                    text = { Text("Unfollow") },
                                    onClick = { showMoreMenu = false; onUnfollow() },
                                    leadingIcon = { Icon(NostrVaultIcons.Blocked, null, tint = ZapOrange) },
                                )
                            } else {
                                DropdownMenuItem(
                                    text = { Text("Follow") },
                                    onClick = { showMoreMenu = false; onFollow() },
                                    leadingIcon = { Icon(NostrVaultIcons.PersonAdd, null, tint = RepostGreen) },
                                )
                            }
                            DropdownMenuItem(
                                text = { Text("Block", color = LikeRed) },
                                onClick = { showMoreMenu = false; onBlock() },
                                leadingIcon = { Icon(NostrVaultIcons.Blocked, null, tint = LikeRed) },
                            )
                            DropdownMenuItem(
                                text = { Text("Report", color = LikeRed) },
                                onClick = { showMoreMenu = false; onReport() },
                                leadingIcon = { Icon(NostrVaultIcons.Alert, null, tint = LikeRed) },
                            )
                        }
                    }
                }
            }

            Spacer(Modifier.height(16.dp))

            // Content
            if (note.content.isNotBlank()) {
                Text(
                    text = note.content,
                    color = PrimaryText,
                    fontSize = 17.sp,
                    lineHeight = 24.sp,
                )
                Spacer(Modifier.height(12.dp))
            }

            // Media
            if (note.mediaURLs.isNotEmpty()) {
                MediaPreviewRow(urls = note.mediaURLs)
                Spacer(Modifier.height(12.dp))
            }

            // Full timestamp
            Text(
                text = dateFormat.format(note.createdAt),
                color = TertiaryText,
                fontSize = 13.sp,
            )

            Spacer(Modifier.height(12.dp))
            HorizontalDivider(color = SeparatorColor, thickness = 0.5.dp)
            Spacer(Modifier.height(12.dp))

            // Engagement stats row (tappable)
            Row(
                horizontalArrangement = Arrangement.SpaceEvenly,
                modifier = Modifier.fillMaxWidth(),
            ) {
                EngagementStat(count = stats?.reactions ?: 0, label = "Likes", onClick = onReactionsClick)
                EngagementStat(count = stats?.reposts ?: 0, label = "Reposts", onClick = onRepostsClick)
                EngagementStat(count = stats?.zaps ?: 0, label = "Zaps", onClick = onZapsClick)
            }

            Spacer(Modifier.height(12.dp))
            HorizontalDivider(color = SeparatorColor, thickness = 0.5.dp)
            Spacer(Modifier.height(8.dp))

            // Action buttons
            Row(
                horizontalArrangement = Arrangement.SpaceEvenly,
                modifier = Modifier.fillMaxWidth(),
            ) {
                IconButton(onClick = onReply) {
                    Icon(NostrVaultIcons.Reply, "Reply", tint = SecondaryText)
                }
                // Repost / Quote dropdown
                Box {
                    IconButton(onClick = { showRepostMenu = true }) {
                        Icon(NostrVaultIcons.Repost, "Repost", tint = SecondaryText)
                    }
                    DropdownMenu(
                        expanded = showRepostMenu,
                        onDismissRequest = { showRepostMenu = false },
                    ) {
                        DropdownMenuItem(
                            text = { Text("Repost") },
                            onClick = { showRepostMenu = false; onRepost() },
                            leadingIcon = { Icon(NostrVaultIcons.Repost, null, tint = RepostGreen) },
                        )
                        DropdownMenuItem(
                            text = { Text("Quote") },
                            onClick = { showRepostMenu = false; onQuote() },
                            leadingIcon = { Icon(NostrVaultIcons.Quote, null, tint = SecondaryText) },
                        )
                    }
                }
                // Like with long-press for emoji picker
                IconButton(
                    onClick = onLike,
                    modifier = Modifier.combinedClickable(
                        onClick = onLike,
                        onLongClick = onLongPressLike,
                    ),
                ) {
                    Icon(
                        imageVector = if (isLiked) NostrVaultIcons.HeartFilled else NostrVaultIcons.Heart,
                        contentDescription = "Like",
                        tint = if (isLiked) LikeRed else SecondaryText,
                    )
                }
                IconButton(onClick = {}) {
                    Icon(NostrVaultIcons.Zap, "Zap", tint = SecondaryText)
                }
                IconButton(onClick = {}) {
                    Icon(NostrVaultIcons.Share, "Share", tint = SecondaryText)
                }
            }
        }
    }
}

@Composable
private fun EngagementStat(count: Int, label: String, onClick: () -> Unit = {}) {
    Row(
        verticalAlignment = Alignment.CenterVertically,
        modifier = Modifier.clickable(onClick = onClick),
    ) {
        Text(
            text = count.toString(),
            color = PrimaryText,
            fontSize = 15.sp,
            fontWeight = FontWeight.Bold,
        )
        Spacer(Modifier.width(4.dp))
        Text(
            text = label,
            color = SecondaryText,
            fontSize = 14.sp,
        )
    }
}
