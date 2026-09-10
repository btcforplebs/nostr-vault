package com.nostrvault.ui.screens

import android.content.Intent
import android.widget.Toast
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
import androidx.compose.material3.pulltorefresh.PullToRefreshBox
import androidx.compose.runtime.*
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.layout.ContentScale
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import androidx.hilt.navigation.compose.hiltViewModel
import androidx.lifecycle.SavedStateHandle
import androidx.lifecycle.ViewModel
import androidx.lifecycle.viewModelScope
import coil.compose.AsyncImage
import com.nostrvault.data.local.ConfigStore
import com.nostrvault.data.model.*
import com.nostrvault.service.FeedService
import com.nostrvault.service.NostrService
import com.nostrvault.service.ZapSendService
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

/** Loading-row fallback when relays never send EOSE (iOS uses 6 s too). */
private const val LOADING_TIMEOUT_MS = 6_000L

@HiltViewModel
class NoteDetailViewModel @Inject constructor(
    savedStateHandle: SavedStateHandle,
    private val nostrService: NostrService,
    private val feedService: FeedService,
    private val configStore: ConfigStore,
    private val zapSendService: ZapSendService,
) : ViewModel() {

    val noteId: String = savedStateHandle["noteId"] ?: ""

    // Direct service access for BroadcastSheet (matches FeedViewModel).
    val feedServiceRef: FeedService get() = feedService
    val nostrServiceRef: NostrService get() = nostrService
    val configStoreRef: ConfigStore get() = configStore

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

    // Staged loading (iOS parity): the hero renders immediately; parents and
    // replies show inline loading states while their fetches are in flight.
    // isLoadingNote covers only the fetch-by-id fallback for uncached notes.
    private val _isLoadingNote = MutableStateFlow(false)
    val isLoadingNote: StateFlow<Boolean> = _isLoadingNote.asStateFlow()

    private val _isLoadingParents = MutableStateFlow(false)
    val isLoadingParents: StateFlow<Boolean> = _isLoadingParents.asStateFlow()

    private val _isLoadingReplies = MutableStateFlow(false)
    val isLoadingReplies: StateFlow<Boolean> = _isLoadingReplies.asStateFlow()

    private val _isRefreshing = MutableStateFlow(false)
    val isRefreshing: StateFlow<Boolean> = _isRefreshing.asStateFlow()

    private val _isCompact = MutableStateFlow(configStore.config.value.noteDetailCompactView)
    val isCompact: StateFlow<Boolean> = _isCompact.asStateFlow()

    // Engagement details for the focused (hero) note
    private val _engagementDetails = MutableStateFlow<EngagementDetails?>(null)
    val engagementDetails: StateFlow<EngagementDetails?> = _engagementDetails.asStateFlow()

    // Thread-wide engagement stats
    private val _expandedEngagement = MutableStateFlow(configStore.config.value.noteDetailExpandedEngagement)
    val expandedEngagement: StateFlow<Boolean> = _expandedEngagement.asStateFlow()

    // Zap state: transient user-facing messages + in-flight guard
    private val _zapMessage = MutableSharedFlow<String>(extraBufferCapacity = 4)
    val zapMessage: SharedFlow<String> = _zapMessage
    private val _isZapping = MutableStateFlow(false)
    val isZapping: StateFlow<Boolean> = _isZapping.asStateFlow()

    private val _perNoteEngagement = MutableStateFlow<Map<String, EngagementDetails>>(emptyMap())
    val perNoteEngagement: StateFlow<Map<String, EngagementDetails>> = _perNoteEngagement.asStateFlow()

    init {
        loadNoteThread()
        // Optimistic reply insertion: when the user publishes a reply from
        // ComposeNoteScreen it is emitted here immediately, before relay
        // confirmation, so it appears inline without waiting for a round-trip.
        viewModelScope.launch {
            feedService.optimisticNote.collect { note ->
                mergeReplies(listOf(note))
            }
        }
    }

    private fun loadNoteThread() {
        val cached = feedService.findNote(noteId)
        if (cached != null) {
            startThreadLoad(cached)
            return
        }
        // Not in the in-memory feed cache (opened from an engagement sheet,
        // old screen, etc.) — fall back to fetching the note itself by id
        // from the relays before declaring it not found (iOS wrapper parity).
        _isLoadingNote.value = true
        nostrService.fetchNoteById(noteId, onRawEvent = feedService::cacheRawEvent) { fetched ->
            _isLoadingNote.value = false
            if (fetched != null) startThreadLoad(fetched)
        }
    }

    /**
     * Kick off the thread + engagement fetches around [foundNote]. Safe to
     * call again for pull-to-refresh: merges are idempotent and existing
     * state is never nulled. [showLoadingStates] drives the inline loading
     * rows; refresh keeps the current content visible instead.
     */
    private fun startThreadLoad(foundNote: FeedNote, showLoadingStates: Boolean = true) {
        _note.value = foundNote

        // Add the opened note into the reply pool immediately so it shows up as
        // a child when its parent is focused. Without this, legacy notes that
        // only tag their direct parent (not the thread root) are never returned
        // by the #e:[rootId] relay query, so focusing the parent shows "No replies".
        mergeReplies(listOf(foundNote))

        // Initial ancestor chain from the in-memory cache.
        val cachedChain = buildAncestorChain(foundNote, _allReplies.value)
        _parentNotes.value = cachedChain

        if (showLoadingStates) {
            // Parents reveal atomically (iOS parity) — unless the cached
            // chain already reaches a top-level note, in which case it is
            // complete and can show immediately.
            val chainComplete = foundNote.parentEventId == null ||
                (cachedChain.isNotEmpty() && cachedChain.first().parentEventId == null)
            _isLoadingParents.value = !chainComplete
            _isLoadingReplies.value = true
        }

        // Fetch the whole thread by NIP-10 root so a mid-thread reply opens
        // with its siblings + ancestors (matching iOS), not just the opened
        // note's direct replies. Ancestor e-tags (minus mentions) are
        // fetched by id to fill any gaps in the chain. For kind-6 reposts
        // both root and focus redirect to the reposted (inner) event so the
        // original's replies are actually found.
        val effectiveId = foundNote.effectiveEventId
        val rootId = foundNote.threadRootId
        val ancestorIds = foundNote.tags
            .filter { it.size >= 2 && it[0] == "e" && (it.size < 4 || it[3] != "mention") }
            .map { it[1] }
        nostrService.fetchThread(rootId, effectiveId, ancestorIds, onRawEvent = feedService::cacheRawEvent) { threadNotes ->
            mergeReplies(threadNotes)
            // Rebuild the chain now that fetched notes may fill gaps.
            _parentNotes.value = buildAncestorChain(foundNote, _allReplies.value)
            _isLoadingParents.value = false
            _isLoadingReplies.value = false
            _isRefreshing.value = false
            fetchMissingThreadProfiles(foundNote)
            if (_expandedEngagement.value && _perNoteEngagement.value.isEmpty()) {
                fetchThreadEngagement()
            }
        }
        // Relays that never EOSE must not leave the loading rows up forever.
        viewModelScope.launch {
            kotlinx.coroutines.delay(LOADING_TIMEOUT_MS)
            _isLoadingParents.value = false
            _isLoadingReplies.value = false
            _isRefreshing.value = false
        }

        fetchMissingThreadProfiles(foundNote)
        fetchEngagement(effectiveId)
    }

    private fun fetchMissingThreadProfiles(foundNote: FeedNote) {
        val pubkeys = buildList {
            addAll(_parentNotes.value.map { it.pubkey })
            add(foundNote.pubkey)
            addAll(_allReplies.value.map { it.pubkey })
        }.distinct()
        nostrService.fetchMissingProfiles(pubkeys)
    }

    /** Idempotent merge — fetch callbacks fire once per relay EOSE. */
    private fun mergeReplies(incoming: List<FeedNote>) {
        if (incoming.isEmpty()) return
        _allReplies.value = (_allReplies.value + incoming)
            .distinctBy { it.id }
            .sortedBy { it.createdAt }
    }

    /**
     * Pull in replies that tag only the newly focused note (legacy clients
     * skip the root tag); called when the thread view refocuses. Also
     * queries the note's known children so nested legacy chains resolve a
     * level deeper. Shows the replies-loading row while nothing is known
     * yet, and fetches profiles for newly discovered repliers.
     */
    fun fetchRepliesForFocus(targetId: String) {
        val knownChildIds = _allReplies.value
            .filter { it.parentEventId == targetId }
            .map { it.id }
        if (knownChildIds.isEmpty()) _isLoadingReplies.value = true
        nostrService.fetchRepliesFor(
            listOf(targetId) + knownChildIds,
            onRawEvent = feedService::cacheRawEvent,
        ) { notes ->
            mergeReplies(notes)
            _isLoadingReplies.value = false
            nostrService.fetchMissingProfiles(notes.map { it.pubkey }.distinct())
        }
        viewModelScope.launch {
            kotlinx.coroutines.delay(LOADING_TIMEOUT_MS)
            _isLoadingReplies.value = false
        }
    }

    /** Pull-to-refresh: re-run the thread fetch without nulling state. */
    fun refresh() {
        val current = _note.value ?: return
        if (_isRefreshing.value) return
        _isRefreshing.value = true
        startThreadLoad(current, showLoadingStates = false)
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
        configStore.update { it.copy(noteDetailCompactView = _isCompact.value) }
    }

    /**
     * Real NIP-57 zap of [note] (effective id handles kind-6 reposts).
     * Result is surfaced through [zapMessage]; engagement re-fetches after a
     * delay so the kind-9735 receipt has time to propagate (iOS parity).
     */
    fun zapNote(note: FeedNote, amountSats: Int) {
        if (_isZapping.value) return
        viewModelScope.launch {
            _isZapping.value = true
            val result = zapSendService.zapNote(note.effectiveEventId, note.pubkey, amountSats)
            _isZapping.value = false
            result.fold(
                onSuccess = {
                    _zapMessage.emit("Zapped ⚡$amountSats sats")
                    kotlinx.coroutines.delay(3_000)
                    fetchEngagement(note.effectiveEventId)
                },
                onFailure = { e -> _zapMessage.emit(e.message ?: "Zap failed") },
            )
        }
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
        configStore.update { it.copy(noteDetailExpandedEngagement = _expandedEngagement.value) }
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

    // ── Quoted note resolution (embedded nostr:note1/nevent1 previews) ──

    val quotedNotesCache: StateFlow<Map<String, FeedNote>> = feedService.parentNotesCache

    fun quotedNoteFor(identifier: String): FeedNote? = feedService.quotedNoteFor(identifier)

    fun fetchMissingQuotedNotes(identifiers: List<String>) =
        feedService.fetchMissingQuotedNotes(identifiers)

    fun fetchMissingQuotedProfiles(identifiers: List<String>) =
        feedService.fetchMissingQuotedProfiles(identifiers)
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
    val isLoadingNote by viewModel.isLoadingNote.collectAsState()
    val isLoadingParents by viewModel.isLoadingParents.collectAsState()
    val isLoadingReplies by viewModel.isLoadingReplies.collectAsState()
    val isRefreshing by viewModel.isRefreshing.collectAsState()
    val isCompact by viewModel.isCompact.collectAsState()
    val engagementDetails by viewModel.engagementDetails.collectAsState()
    val expandedEngagement by viewModel.expandedEngagement.collectAsState()
    val perNoteEngagement by viewModel.perNoteEngagement.collectAsState()
    val profiles by viewModel.profiles.collectAsState()
    val quotedNotesCache by viewModel.quotedNotesCache.collectAsState()
    val colors = LocalNostrVaultColors.current
    val listState = rememberLazyListState()
    val scope = rememberCoroutineScope()
    val context = LocalContext.current

    // The currently focused note (hero). Starts as the original note,
    // tapping a parent or reply refocuses the thread around it.
    var focusedNoteId by remember { mutableStateOf(noteId) }

    // Fetch any embedded quoted notes (nostr:note1.../nevent1...) referenced by
    // the focal note, its ancestors, or replies, plus their authors' profiles.
    LaunchedEffect(note, parentNotes, allReplies) {
        val quotedIds = buildList {
            note?.let { addAll(it.quotedEventIds) }
            parentNotes.forEach { addAll(it.quotedEventIds) }
            allReplies.forEach { addAll(it.quotedEventIds) }
        }.distinct()
        if (quotedIds.isNotEmpty()) viewModel.fetchMissingQuotedNotes(quotedIds)
    }
    LaunchedEffect(note, parentNotes, allReplies, quotedNotesCache) {
        val quotedIds = buildList {
            note?.let { addAll(it.quotedEventIds) }
            parentNotes.forEach { addAll(it.quotedEventIds) }
            allReplies.forEach { addAll(it.quotedEventIds) }
        }.distinct()
        if (quotedIds.isNotEmpty()) viewModel.fetchMissingQuotedProfiles(quotedIds)
    }

    // Engagement sheet states
    var showReactorsSheet by remember { mutableStateOf(false) }
    var showZappersSheet by remember { mutableStateOf(false) }
    var showRepostersSheet by remember { mutableStateOf(false) }

    // Emoji picker / zap / broadcast targets — any note in the thread, not
    // just the hero (parents and replies have the same action bar).
    var emojiTargetNote by remember { mutableStateOf<FeedNote?>(null) }
    var zapTargetNote by remember { mutableStateOf<FeedNote?>(null) }
    val zapSheetState = rememberModalBottomSheetState(skipPartiallyExpanded = true)
    var broadcastTargetNote by remember { mutableStateOf<FeedNote?>(null) }
    val broadcastSheetState = rememberModalBottomSheetState(skipPartiallyExpanded = true)

    fun shareNote(target: FeedNote) {
        val shareText = target.content.ifBlank { "nostr:${target.effectiveEventId}" }
        val intent = Intent(Intent.ACTION_SEND).apply {
            type = "text/plain"
            putExtra(Intent.EXTRA_TEXT, shareText)
        }
        context.startActivity(Intent.createChooser(intent, "Share Note"))
    }

    // Delete confirmation
    var showDeleteDialog by remember { mutableStateOf(false) }
    var showBlockDialog by remember { mutableStateOf(false) }

    // Zap result feedback
    LaunchedEffect(Unit) {
        viewModel.zapMessage.collect { msg ->
            Toast.makeText(context, msg, Toast.LENGTH_SHORT).show()
        }
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
        // Effective id redirects kind-6 reposts to the reposted event, whose
        // replies are what actually exist on relays.
        val heroId = focusedNote?.effectiveEventId ?: noteId
        allReplies.filter { it.parentEventId == heroId }.sortedBy { it.createdAt }
    }

    // Re-fetch engagement when focus changes; when refocusing inside the
    // thread also pull replies that tag only that note, since legacy clients
    // skip the root tag (iOS fetchRepliesForNote parity).
    LaunchedEffect(focusedNoteId) {
        val target = focusedNote?.effectiveEventId ?: focusedNoteId
        viewModel.fetchEngagement(target)
        if (focusedNoteId != noteId) viewModel.fetchRepliesForFocus(target)
    }

    // Auto-scroll to hero note when focus changes or the parent chain is
    // revealed. This replaces both the initial scroll and tap-to-focus scroll.
    LaunchedEffect(focusedNoteId, isLoadingParents) {
        if (!isLoadingParents && note != null) {
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
                    IconButton(onClick = { focusedNote?.let { onReply(it.effectiveEventId) } }, modifier = Modifier.size(40.dp)) {
                        Icon(NostrVaultIcons.Reply, "Reply", tint = SecondaryText, modifier = Modifier.size(25.dp))
                    }
                    // Broadcast
                    IconButton(onClick = { broadcastTargetNote = focusedNote }, modifier = Modifier.size(40.dp)) {
                        Icon(NostrVaultIcons.Relay, "Broadcast", tint = SecondaryText, modifier = Modifier.size(25.dp))
                    }
                }
            }
        },
    ) { padding ->
        if (isLoadingNote) {
            // Only while the fetch-by-id fallback runs for an uncached note.
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
            PullToRefreshBox(
                isRefreshing = isRefreshing,
                onRefresh = viewModel::refresh,
                modifier = Modifier.fillMaxSize(),
            ) {
            LazyColumn(
                state = listState,
                contentPadding = padding,
                modifier = Modifier.fillMaxSize(),
            ) {
                // ── Parent chain ────────────────────────────────
                // Revealed atomically once loaded (iOS parity): a partial
                // cached chain growing above the viewport causes repeated
                // LazyColumn anchor jumps.
                if (isLoadingParents) {
                    if (note?.parentEventId != null) {
                        item(key = "parents_loading") {
                            InlineLoadingRow(text = "Loading thread…", color = colors.primary)
                        }
                    }
                } else {
                    items(dynamicParents, key = { "parent_${it.id}" }) { parent ->
                        if (isCompact) {
                            CompactParentRow(
                                note = parent,
                                profile = viewModel.profileFor(parent.pubkey),
                                isFocused = parent.id == focusedNoteId,
                                themeColor = colors.primary,
                                onClick = { scrollToNote(parent.id) },
                            )
                        } else {
                            val quotedNotesMap = remember(parent.id, parent.quotedEventIds, quotedNotesCache) {
                                parent.quotedEventIds.mapNotNull { qid ->
                                    viewModel.quotedNoteFor(qid)?.let { qid to it }
                                }.toMap()
                            }
                            NoteCard(
                                note = parent,
                                profile = viewModel.profileFor(parent.pubkey),
                                stats = viewModel.statsFor(parent.id),
                                profiles = profiles,
                                quotedNotes = quotedNotesMap,
                                isLiked = viewModel.isLiked(parent.id),
                                isFocused = parent.id == focusedNoteId,
                                parentIsNext = true,
                                onNoteClick = { scrollToNote(parent.id) },
                                onProfileClick = onProfileClick,
                                onLike = viewModel::likeNote,
                                onRepost = viewModel::repostNote,
                                onQuote = onQuote,
                                onReply = onReply,
                                onZap = { zapTargetNote = parent },
                                onShare = { shareNote(parent) },
                                onBroadcast = { broadcastTargetNote = parent },
                                onLongPressLike = { emojiTargetNote = parent },
                            )
                        }
                        // Thread connector line
                        ThreadConnectorLine(color = colors.primary)
                    }
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
                        onLike = { viewModel.likeNote(focusedNote!!.effectiveEventId) },
                        onLongPressLike = { emojiTargetNote = focusedNote },
                        onRepost = { viewModel.repostNote(focusedNote!!.effectiveEventId) },
                        onQuote = { onQuote(focusedNote!!.effectiveEventId) },
                        onReply = { onReply(focusedNote!!.effectiveEventId) },
                        onFollow = { viewModel.followUser(focusedNote!!.pubkey) },
                        onUnfollow = { viewModel.unfollowUser(focusedNote!!.pubkey) },
                        onBlock = { showBlockDialog = true },
                        onDelete = { showDeleteDialog = true },
                        onReport = { viewModel.reportNote(focusedNote!!.effectiveEventId, focusedNote!!.pubkey, "spam") },
                        onReactionsClick = { showReactorsSheet = true },
                        onRepostsClick = { showRepostersSheet = true },
                        onZapsClick = { showZappersSheet = true },
                        onZap = { zapTargetNote = focusedNote },
                        onShare = { shareNote(focusedNote!!) },
                        onBroadcast = { broadcastTargetNote = focusedNote },
                    )
                }

                // ── Replies: loading / empty / header ───────────
                if (isLoadingReplies && directReplies.isEmpty()) {
                    item(key = "replies_loading") {
                        InlineLoadingRow(text = "Loading replies…", color = colors.primary)
                    }
                } else if (directReplies.isEmpty()) {
                    item(key = "replies_empty") {
                        Text(
                            text = "No replies yet",
                            color = SecondaryText,
                            fontSize = 13.sp,
                            modifier = Modifier
                                .fillMaxWidth()
                                .padding(vertical = 24.dp),
                            textAlign = androidx.compose.ui.text.style.TextAlign.Center,
                        )
                    }
                } else {
                    item(key = "replies_header") {
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
                        onReply = onReply,
                        onQuote = onQuote,
                        onZapNote = { zapTargetNote = it },
                        onShareNote = { shareNote(it) },
                        onBroadcastNote = { broadcastTargetNote = it },
                        onLongPressLikeNote = { emojiTargetNote = it },
                    )
                }

                // Bottom spacer
                item { Spacer(Modifier.height(32.dp)) }
            }
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
    emojiTargetNote?.let { target ->
        val emojiSheetState = rememberModalBottomSheetState(skipPartiallyExpanded = true)
        EmojiPickerSheet(
            sheetState = emojiSheetState,
            onDismiss = { emojiTargetNote = null },
            onSelectEmoji = { emoji ->
                viewModel.reactToNote(target.effectiveEventId, emoji)
                emojiTargetNote = null
            },
        )
    }
    zapTargetNote?.let { target ->
        CustomZapSheet(
            sheetState = zapSheetState,
            onDismiss = { zapTargetNote = null },
            onZap = { amount ->
                viewModel.zapNote(target, amount)
                zapTargetNote = null
            },
        )
    }
    broadcastTargetNote?.let { target ->
        BroadcastSheet(
            note = target,
            sheetState = broadcastSheetState,
            feedService = viewModel.feedServiceRef,
            nostrService = viewModel.nostrServiceRef,
            configStore = viewModel.configStoreRef,
            onDismiss = { broadcastTargetNote = null },
        )
    }
}

// ── Inline loading row (iOS "Loading thread…" / "Loading replies…") ──

@Composable
private fun InlineLoadingRow(text: String, color: androidx.compose.ui.graphics.Color) {
    Row(
        verticalAlignment = Alignment.CenterVertically,
        horizontalArrangement = Arrangement.Center,
        modifier = Modifier
            .fillMaxWidth()
            .padding(vertical = 16.dp),
    ) {
        CircularProgressIndicator(
            color = color,
            strokeWidth = 2.dp,
            modifier = Modifier.size(16.dp),
        )
        Spacer(Modifier.width(8.dp))
        Text(text = text, color = SecondaryText, fontSize = 12.sp)
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
    onReply: (String) -> Unit,
    onQuote: (String) -> Unit,
    onZapNote: (FeedNote) -> Unit,
    onShareNote: (FeedNote) -> Unit,
    onBroadcastNote: (FeedNote) -> Unit,
    onLongPressLikeNote: (FeedNote) -> Unit,
) {
    // Keyed on the reply list too: late-arriving replies (refocus fetch,
    // pull-to-refresh) must recompute each node's children.
    val allRepliesState by viewModel.allReplies.collectAsState()
    val childReplies = remember(reply.id, allRepliesState) { viewModel.childRepliesFor(reply.id) }
    val isFocusedReply = reply.id == focusedNoteId
    val quotedNotesCache by viewModel.quotedNotesCache.collectAsState()
    val quotedNotesMap = remember(reply.id, reply.quotedEventIds, quotedNotesCache) {
        reply.quotedEventIds.mapNotNull { qid ->
            viewModel.quotedNoteFor(qid)?.let { qid to it }
        }.toMap()
    }

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
                            onReply = onReply,
                            onQuote = onQuote,
                            onZapNote = onZapNote,
                            onShareNote = onShareNote,
                            onBroadcastNote = onBroadcastNote,
                            onLongPressLikeNote = onLongPressLikeNote,
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
                profiles = profiles,
                quotedNotes = quotedNotesMap,
                isLiked = viewModel.isLiked(reply.id),
                isFocused = isFocusedReply,
                onNoteClick = { onFocus(reply.id) },
                onProfileClick = onProfileClick,
                onLike = viewModel::likeNote,
                onRepost = viewModel::repostNote,
                onQuote = onQuote,
                onReply = onReply,
                onZap = { onZapNote(reply) },
                onShare = { onShareNote(reply) },
                onBroadcast = { onBroadcastNote(reply) },
                onLongPressLike = { onLongPressLikeNote(reply) },
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
                                    onReply = onReply,
                                    onQuote = onQuote,
                                    onZapNote = onZapNote,
                                    onShareNote = onShareNote,
                                    onBroadcastNote = onBroadcastNote,
                                    onLongPressLikeNote = onLongPressLikeNote,
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
    onZap: () -> Unit,
    onShare: () -> Unit,
    onBroadcast: () -> Unit,
) {
    val dateFormat = remember { SimpleDateFormat("MMM d, yyyy 'at' h:mm a", Locale.getDefault()) }
    var showMoreMenu by remember { mutableStateOf(false) }

    Surface(
        color = SecondaryGroupedBg.copy(alpha = 0.85f),
        shape = RoundedCornerShape(12.dp),
        border = androidx.compose.foundation.BorderStroke(2.dp, themeColor),
        shadowElevation = 4.dp,
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

            // Engagement stats row — only shown when at least one count is non-zero
            val reactions = stats?.reactions ?: 0
            val reposts = stats?.reposts ?: 0
            val zaps = stats?.zaps ?: 0
            if (reactions > 0 || reposts > 0 || zaps > 0) {
                Spacer(Modifier.height(12.dp))
                Row(
                    horizontalArrangement = Arrangement.SpaceEvenly,
                    modifier = Modifier.fillMaxWidth(),
                ) {
                    if (reactions > 0) EngagementStat(count = reactions, label = "Likes", onClick = onReactionsClick)
                    if (reposts > 0) EngagementStat(count = reposts, label = "Reposts", onClick = onRepostsClick)
                    if (zaps > 0) EngagementStat(count = zaps, label = "Zaps", onClick = onZapsClick)
                }
                Spacer(Modifier.height(12.dp))
                HorizontalDivider(color = SeparatorColor, thickness = 0.5.dp)
            }

            Spacer(Modifier.height(8.dp))

            // Action buttons — identical layout to NoteCard EngagementBar
            Row(
                horizontalArrangement = Arrangement.spacedBy(6.dp),
                verticalAlignment = Alignment.CenterVertically,
                modifier = Modifier.fillMaxWidth(),
            ) {
                EngagementButton(
                    icon = NostrVaultIcons.Reply,
                    isActive = false,
                    activeColor = SecondaryText,
                    contentDescription = "Reply",
                    onClick = onReply,
                )
                EngagementButton(
                    icon = NostrVaultIcons.Repost,
                    isActive = false,
                    activeColor = RepostGreen,
                    contentDescription = "Repost",
                    onClick = onRepost,
                )
                EngagementButton(
                    icon = NostrVaultIcons.Quote,
                    isActive = false,
                    activeColor = SecondaryText,
                    contentDescription = "Quote",
                    onClick = onQuote,
                )
                // Like with long-press for emoji picker
                EngagementButton(
                    icon = if (isLiked) NostrVaultIcons.HeartFilled else NostrVaultIcons.Heart,
                    isActive = isLiked,
                    activeColor = LikeRed,
                    contentDescription = if (isLiked) "Unlike" else "Like",
                    onClick = onLike,
                    onLongClick = onLongPressLike,
                )
                EngagementButton(
                    icon = NostrVaultIcons.Zap,
                    isActive = false,
                    activeColor = ZapOrange,
                    contentDescription = "Zap",
                    onClick = onZap,
                )
                EngagementButton(
                    icon = NostrVaultIcons.Share,
                    isActive = false,
                    activeColor = SecondaryText,
                    contentDescription = "Share",
                    onClick = onShare,
                )
                EngagementButton(
                    icon = NostrVaultIcons.Relay,
                    isActive = false,
                    activeColor = SecondaryText,
                    contentDescription = "Broadcast",
                    onClick = onBroadcast,
                )
                Spacer(Modifier.weight(1f))
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
