package com.nostrvault.ui.screens

import com.nostrvault.ui.components.ZapFlight
import android.widget.Toast
import androidx.compose.animation.animateContentSize
import androidx.compose.foundation.ExperimentalFoundationApi
import androidx.compose.foundation.background
import androidx.compose.foundation.border
import androidx.compose.foundation.clickable
import androidx.compose.foundation.combinedClickable
import androidx.compose.foundation.interaction.DragInteraction
import androidx.compose.foundation.layout.*
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
import androidx.compose.ui.geometry.Size
import androidx.compose.ui.geometry.Offset
import androidx.compose.ui.draw.drawBehind
import androidx.compose.ui.draw.clip
import androidx.compose.ui.draw.shadow
import androidx.compose.ui.layout.ContentScale
import androidx.compose.ui.platform.LocalClipboardManager
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.platform.LocalDensity
import androidx.compose.ui.text.AnnotatedString
import androidx.compose.ui.semantics.contentDescription
import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.text.font.FontFamily
import androidx.compose.ui.text.font.FontStyle
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
import com.nostrvault.service.FeedFilterEngine
import com.nostrvault.service.FeedService
import com.nostrvault.service.NostrService
import com.nostrvault.service.ZapSendService
import com.nostrvault.relay.HavenBridge
import com.nostrvault.ui.components.*
import com.nostrvault.ui.theme.*
import dagger.hilt.android.lifecycle.HiltViewModel
import kotlinx.coroutines.flow.*
import kotlinx.coroutines.launch
import java.util.*
import javax.inject.Inject

/**
 * Thread view for a single note with parent chain, nested replies,
 * tap-to-focus navigation, and depth-based collapsing.
 * Port of NoteDetailView.swift.
 */

/** Loading-row fallback when relays never send EOSE (iOS uses 6 s too). */
private const val LOADING_TIMEOUT_MS = 6_000L

/**
 * A response that isn't a thread row: a quote (a `q` tag on the root, and not
 * itself a reply), a highlight, a voice reply, or any other kind pointing at
 * the root. Replies, comments, reactions, reposts and zaps live elsewhere.
 * iOS: NoteDetailView.isOtherResponse.
 */
internal fun isOtherResponse(note: FeedNote, rootId: String): Boolean {
    if (note.kind in setOf(1, NIP10Thread.COMMENT_KIND, 6, 7, 9735)) {
        if (note.kind != 1) return false
        val quotesRoot = note.tags.any { it.size >= 2 && it[0] == "q" && it[1] == rootId }
        return quotesRoot && NIP10Thread.parentEventId(note.kind, note.tags) == null
    }
    return true
}

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

    /** Quotes, highlights and voice replies: shown under the thread, not as rows. */
    private val _otherResponses = MutableStateFlow<List<FeedNote>>(emptyList())
    val otherResponses: StateFlow<List<FeedNote>> = _otherResponses.asStateFlow()

    val profiles: StateFlow<Map<String, FeedProfile>> = nostrService.profiles
    val noteStats: StateFlow<Map<String, NoteStats>> = feedService.noteStats
    val likedEventIds: StateFlow<Set<String>> = feedService.likedEventIds
    val repostedEventIds: StateFlow<Set<String>> = feedService.repostedEventIds

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

    /** The active account's blocked people (hex), kept current so blocking from here hides them at once. */
    val blockedPubkeys: StateFlow<Set<String>> = configStore.config
        .map { feedService.blockedHexForActiveAccount() }
        .stateIn(viewModelScope, SharingStarted.Eagerly, feedService.blockedHexForActiveAccount())

    /**
     * Your Web of Trust plus follows, taken once the graph has loaded. Empty
     * until then, which folds nobody. iOS: `feedService.relayTabTrustedPubkeys()`.
     */
    private val _trustedPubkeys = MutableStateFlow<Set<String>>(emptySet())
    val trustedPubkeys: StateFlow<Set<String>> = _trustedPubkeys.asStateFlow()

    val activeHexPubkey: String get() = nostrService.activeHexPubkey

    init {
        loadNoteThread()
        viewModelScope.launch {
            if (feedService.wotPubkeys.value.isEmpty()) feedService.loadWotPubkeys()
            val wot = feedService.wotPubkeys.first { it.isNotEmpty() }
            _trustedPubkeys.value = wot + feedService.followedPubkeys.value
        }
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
        feedService.cacheNote(foundNote)

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
        // The root's address when it's addressable or replaceable (or the
        // A a comment carries), so comments on an edited article still load.
        val rootCoordinate = if (foundNote.kind == NIP10Thread.COMMENT_KIND) {
            foundNote.tags.firstOrNull { it.size >= 2 && it[0] == "A" }?.get(1)
        } else if (rootId == foundNote.id) {
            NIP10Thread.coordinate(foundNote.kind, foundNote.pubkey, foundNote.tags)
        } else null
        nostrService.fetchOtherResponses(rootId, rootCoordinate) { found ->
            _otherResponses.value = found
                .filter { isOtherResponse(it, rootId) && !FeedNote.isNoiseOrSpam(it.content, it.tags) }
                .sortedByDescending { it.createdAt }
            nostrService.fetchMissingProfiles(found.map { it.pubkey }.distinct())
        }
        nostrService.fetchThread(rootId, effectiveId, ancestorIds, rootCoordinate, onRawEvent = feedService::cacheRawEvent) { threadNotes ->
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
        incoming.forEach { feedService.cacheNote(it) }
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
                    ZapFlight.launch(note.effectiveEventId)
                    _zapMessage.emit("Zapped $amountSats sats")
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

    fun reportNote(noteId: String, pubkey: String, reason: String, description: String = "") {
        viewModelScope.launch {
            nostrService.reportEvent(noteId, pubkey, reason, description.ifBlank { null })
            // iOS UGCReportingDialog also blocks the reported user.
            feedService.blockUser(pubkey)
        }
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

    /**
     * The people in one thread note's engagement, for its sheet. The thread
     * batch fetch does not load them (the focused note's own fetch does), so
     * this runs once when a sheet opens rather than for every row.
     */
    fun fetchEngagementProfiles(details: EngagementDetails) {
        val pubkeys = buildList {
            details.reactions.mapTo(this) { it.pubkey }
            details.zaps.mapTo(this) { it.zapperPubkey }
            details.reposts.mapTo(this) { it.pubkey }
        }.distinct()
        if (pubkeys.isNotEmpty()) nostrService.fetchMissingProfiles(pubkeys)
    }

    fun profileFor(pubkey: String): FeedProfile? = profiles.value[pubkey]
    fun statsFor(noteId: String): NoteStats? = noteStats.value[noteId]
    fun isLiked(noteId: String): Boolean = likedEventIds.value.contains(noteId)
    fun isReposted(noteId: String): Boolean = repostedEventIds.value.contains(noteId)

    /** A note this thread or the feed has loaded: what a bare repost line carries. */
    fun findNote(id: String): FeedNote? =
        feedService.findNote(id) ?: _allReplies.value.firstOrNull { it.id == id }

    // ── Quoted note resolution (embedded nostr:note1/nevent1 previews) ──

    val quotedNotesCache: StateFlow<Map<String, FeedNote>> = feedService.quotedNotes

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
    /** Where a quoted long-form post opens; the note screen would show its Markdown source. */
    onArticleClick: (String) -> Unit,
    onReply: (String) -> Unit,
    onQuote: (String) -> Unit,
    onBack: () -> Unit,
    viewModel: NoteDetailViewModel = hiltViewModel(),
) {
    val note by viewModel.note.collectAsState()
    val parentNotes by viewModel.parentNotes.collectAsState()
    val allReplies by viewModel.allReplies.collectAsState()
    val otherResponses by viewModel.otherResponses.collectAsState()
    val isLoadingNote by viewModel.isLoadingNote.collectAsState()
    val isLoadingParents by viewModel.isLoadingParents.collectAsState()
    val isLoadingReplies by viewModel.isLoadingReplies.collectAsState()
    val isRefreshing by viewModel.isRefreshing.collectAsState()
    val engagementDetails by viewModel.engagementDetails.collectAsState()
    val expandedEngagement by viewModel.expandedEngagement.collectAsState()
    val perNoteEngagement by viewModel.perNoteEngagement.collectAsState()
    val profiles by viewModel.profiles.collectAsState()
    val quotedNotesCache by viewModel.quotedNotesCache.collectAsState()
    val colors = LocalNostrVaultColors.current
    val listState = rememberLazyListState()
    val scope = rememberCoroutineScope()
    val context = LocalContext.current
    val density = LocalDensity.current

    // The currently focused note (hero). Starts as the original note,
    // tapping a parent or reply refocuses the thread around it.
    var focusedNoteId by remember { mutableStateOf(noteId) }

    // Replies and the conversation above drawn as condensed lines, the same
    // lines the threaded feed uses. The note you are reading always stays full
    // size with its action bar, so replying is still one tap: that is what the
    // old compact mode got wrong (iOS #56). Remembered across threads.
    // iOS: @AppStorage("thread.condensedReplies").
    val threadPrefs = remember { context.getSharedPreferences(THREAD_PREFS, android.content.Context.MODE_PRIVATE) }
    var condensedReplies by remember { mutableStateOf(threadPrefs.getBoolean(KEY_CONDENSED_REPLIES, false)) }

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
    // Which list is open and whose: a null note id is the focused note
    // (its own engagement fetch), any other id a note elsewhere in the thread
    // (the thread-wide batch).
    var engagementSheet by remember { mutableStateOf<EngagementSheetTarget?>(null) }

    // Emoji picker / zap / broadcast targets — any note in the thread, not
    // just the hero (parents and replies have the same action bar).
    var emojiTargetNote by remember { mutableStateOf<FeedNote?>(null) }
    var zapTargetNote by remember { mutableStateOf<FeedNote?>(null) }
    val zapSheetState = rememberModalBottomSheetState(skipPartiallyExpanded = true)
    var broadcastTargetNote by remember { mutableStateOf<FeedNote?>(null) }
    val broadcastSheetState = rememberModalBottomSheetState(skipPartiallyExpanded = true)

    // Moderation confirmations. These hold the note they were opened for rather
    // than a flag, because the overflow menu is now on every note on this screen
    // and not only on the focused one. Acting on the focused note still leaves
    // the screen — there is nothing left to look at; acting on a reply does not.
    var deleteTarget by remember { mutableStateOf<FeedNote?>(null) }
    var blockTarget by remember { mutableStateOf<FeedNote?>(null) }
    var reportTarget by remember { mutableStateOf<FeedNote?>(null) }

    // Zap result feedback
    LaunchedEffect(Unit) {
        viewModel.zapMessage.collect { msg ->
            Toast.makeText(context, msg, Toast.LENGTH_SHORT).show()
        }
    }

    val blockedPubkeys by viewModel.blockedPubkeys.collectAsState()
    val trustedPubkeys by viewModel.trustedPubkeys.collectAsState()
    // Replies from outside your network are folded until asked for.
    var showsOutsideReplies by remember { mutableStateOf(false) }

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

    // Notes above it by someone you blocked are left out.
    val shownParents = remember(dynamicParents, blockedPubkeys) {
        dynamicParents.filter { it.pubkey !in blockedPubkeys }
    }

    // Effective id redirects kind-6 reposts to the reposted event, whose
    // replies are what actually exist on relays.
    val replyTargetId = focusedNote?.effectiveEventId ?: noteId

    // Replies under the opened note, at any depth, through the feed's block
    // rule and spam check; replies from outside your network stay folded.
    // You and the authors of the opened note and the notes above it are never
    // folded. iOS: NoteDetailView.threadReplies (#278).
    val threadReplies = remember(
        replyTargetId, allReplies, parentNotes, note, dynamicParents, blockedPubkeys, trustedPubkeys, showsOutsideReplies,
    ) {
        val byId = (parentNotes + listOfNotNull(note) + allReplies).associateBy { it.id }
        val insiders = buildSet {
            add(viewModel.activeHexPubkey)
            note?.let { add(it.pubkey) }
            focusedNote?.let { add(it.pubkey) }
            dynamicParents.forEach { add(it.pubkey) }
        }
        ThreadReplyVisibility.replies(
            targetId = replyTargetId,
            pool = allReplies,
            hidden = { n ->
                n.isNoise || FeedFilterEngine.involvesBlocked(n, blockedPubkeys) { id ->
                    byId[id]?.pubkey ?: viewModel.findNote(id)?.pubkey
                }
            },
            trusted = trustedPubkeys,
            insiders = insiders,
            showOutside = showsOutsideReplies,
        )
    }
    val visibleReplies = threadReplies.visible

    val directReplies = remember(replyTargetId, visibleReplies) {
        visibleReplies.filter { it.parentEventId == replyTargetId }.sortedBy { it.createdAt }
    }

    // Re-fetch engagement when focus changes; when refocusing inside the
    // thread also pull replies that tag only that note, since legacy clients
    // skip the root tag (iOS fetchRepliesForNote parity).
    LaunchedEffect(focusedNoteId) {
        val target = focusedNote?.effectiveEventId ?: focusedNoteId
        viewModel.fetchEngagement(target)
        if (focusedNoteId != noteId) viewModel.fetchRepliesForFocus(target)
    }

    // The hero's place in the list: after the loading row while the notes
    // above it load, then after the parent cards, or after the one card of
    // condensed lines.
    val heroIndex = when {
        isLoadingParents -> if (note?.parentEventId != null) 1 else 0
        condensedReplies -> if (shownParents.isEmpty()) 0 else 1
        else -> shownParents.size
    }
    val currentHeroIndex by rememberUpdatedState(heroIndex)
    val viewportHeight by remember { derivedStateOf { listState.layoutInfo.viewportSize.height } }

    // Set once the reader scrolls or picks another note; until then the
    // opened note is kept at the top as the thread above it loads.
    var readerTookOver by remember { mutableStateOf(false) }
    LaunchedEffect(listState) {
        listState.interactionSource.interactions.collect {
            if (it is DragInteraction.Start) readerTookOver = true
        }
    }

    // Puts the note you opened a little below the top (12% down, so the end
    // of the post it answers shows above it), with the rest of the posts it
    // answers scrollable above. Runs again whenever the content above it
    // changes (history arriving, the layout switching, the screen size
    // settling), until the reader scrolls: a single jump was undone by
    // whatever loaded next, and the opened reply ended up down the screen.
    // iOS #282, #306. The first landing is instant, before the thread has
    // been seen; a later one (history arriving late) glides instead of jumping.
    var hasLanded by remember { mutableStateOf(false) }
    LaunchedEffect(isLoadingParents, heroIndex, viewportHeight, note != null) {
        if (readerTookOver || isLoadingParents || note == null || heroIndex == 0) return@LaunchedEffect
        suspend fun land() {
            if (readerTookOver || heroIndex >= listState.layoutInfo.totalItemsCount) return
            val offset = -(viewportHeight * THREAD_LANDING_ANCHOR).toInt()
            // A negative scroll offset puts the item that far below the top.
            val there = listState.layoutInfo.visibleItemsInfo.firstOrNull { it.index == heroIndex }?.offset == -offset
            if (there) return
            if (hasLanded) listState.animateScrollToItem(heroIndex, offset)
            else listState.scrollToItem(heroIndex, offset)
            hasLanded = true
        }
        // Next frame, once the revealed history has laid out, and once more
        // after images above have had a moment to size themselves.
        withFrameNanos { }
        land()
        kotlinx.coroutines.delay(400)
        land()
    }

    // A note picked in the thread becomes the hero and scrolls to the top.
    LaunchedEffect(focusedNoteId) {
        if (!readerTookOver) return@LaunchedEffect // the opened note: the landing above handles it
        // Allow layout to settle after recomposition
        kotlinx.coroutines.delay(250)
        val index = currentHeroIndex
        if (index in 0 until listState.layoutInfo.totalItemsCount) {
            listState.animateScrollToItem(index)
        }
    }

    fun scrollToNote(targetId: String) {
        readerTookOver = true
        focusedNoteId = targetId
        // LaunchedEffect(focusedNoteId) handles the actual scroll after recomposition
    }

    // Delete confirmation dialog
    deleteTarget?.let { target ->
        AlertDialog(
            onDismissRequest = { deleteTarget = null },
            title = { Text("Delete Post", color = PrimaryText) },
            text = { Text("Request deletion of this post? Not all relays honor NIP-09 deletion requests.", color = SecondaryText) },
            confirmButton = {
                TextButton(
                    onClick = {
                        viewModel.deleteNote(target.id)
                        deleteTarget = null
                        if (target.id == focusedNote?.id) onBack()
                    },
                    colors = ButtonDefaults.textButtonColors(contentColor = LikeRed),
                ) { Text("Delete") }
            },
            dismissButton = {
                TextButton(onClick = { deleteTarget = null }) { Text("Cancel", color = SecondaryText) }
            },
            containerColor = SecondaryGroupedBg,
        )
    }

    // Block confirmation dialog
    blockTarget?.let { target ->
        AlertDialog(
            onDismissRequest = { blockTarget = null },
            title = { Text("Block User", color = PrimaryText) },
            text = { Text("Block this user? Their posts will be hidden from your feed.", color = SecondaryText) },
            confirmButton = {
                TextButton(
                    onClick = {
                        viewModel.blockUser(target.pubkey)
                        blockTarget = null
                        if (target.id == focusedNote?.id) onBack()
                    },
                    colors = ButtonDefaults.textButtonColors(contentColor = LikeRed),
                ) { Text("Block") }
            },
            dismissButton = {
                TextButton(onClick = { blockTarget = null }) { Text("Cancel", color = SecondaryText) }
            },
            containerColor = SecondaryGroupedBg,
        )
    }

    // Report content dialog (NIP-56 reason picker + auto-block)
    reportTarget?.let { target ->
        UGCReportDialog(
            onReport = { reason, description ->
                viewModel.reportNote(target.effectiveEventId, target.pubkey, reason, description)
                reportTarget = null
                if (target.id == focusedNote?.id) onBack()
            },
            onDismiss = { reportTarget = null },
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

                // Trailing pill: condensed toggle + stats + reply + broadcast
                GlassPill {
                    // Condensed / full replies
                    IconButton(
                        onClick = {
                            condensedReplies = !condensedReplies
                            threadPrefs.edit().putBoolean(KEY_CONDENSED_REPLIES, condensedReplies).apply()
                        },
                        modifier = Modifier.size(40.dp),
                    ) {
                        Icon(
                            if (condensedReplies) NostrVaultIcons.ThreadedView else NostrVaultIcons.ExpandedView,
                            if (condensedReplies) "Condensed replies" else "Full replies",
                            tint = if (condensedReplies) colors.primary else SecondaryText,
                            modifier = Modifier.size(25.dp),
                        )
                    }
                    // Thread stats toggle. While on it says "Stats": an icon
                    // alone gave no hint what it had switched on (iOS #325).
                    ThreadStatsToggle(isOn = expandedEngagement, onClick = viewModel::toggleExpandedEngagement)
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
                } else if (condensedReplies) {
                    // The conversation above, one line per note, oldest at the top.
                    if (shownParents.isNotEmpty()) {
                        item(key = "parents_condensed") {
                            CondensedThreadCard {
                                for (parent in shownParents) {
                                    ThreadCondensedLine(
                                        note = parent,
                                        depth = 0,
                                        replyCount = 0,
                                        viewModel = viewModel,
                                        profiles = profiles,
                                        onProfileClick = onProfileClick,
                                        onTap = { scrollToNote(parent.id) },
                                    )
                                }
                            }
                        }
                    }
                } else {
                    items(shownParents, key = { "parent_${it.id}" }) { parent ->
                        val quotedNotesMap = remember(parent.id, parent.quotedEventIds, quotedNotesCache) {
                            parent.quotedEventIds.mapNotNull { qid ->
                                viewModel.quotedNoteFor(qid)?.let { qid to it }
                            }.toMap()
                        }
                        NoteCard(
                            note = parent,
                            profile = viewModel.profileFor(parent.pubkey),
                            profiles = profiles,
                            quotedNotes = quotedNotesMap,
                            isLiked = viewModel.isLiked(parent.id),
                            isReposted = viewModel.isReposted(parent.effectiveEventId),
                            isFocused = parent.id == focusedNoteId,
                            parentIsNext = true,
                            onNoteClick = { scrollToNote(parent.id) },
                            onArticleClick = onArticleClick,
                            onProfileClick = onProfileClick,
                            onLike = viewModel::likeNote,
                            onRepost = viewModel::repostNote,
                            onQuote = onQuote,
                            onReply = onReply,
                            onZap = { zapTargetNote = parent },
                            onBroadcast = { broadcastTargetNote = parent },
                            isOwnNote = viewModel.isOwnNote(parent.pubkey),
                            onReport = { reportTarget = parent },
                            onBlock = { blockTarget = parent },
                            onDelete = { deleteTarget = parent },
                            onLongPressLike = { emojiTargetNote = parent },
                            modifier = Modifier.padding(horizontal = ThreadSideInset),
                        )
                        if (expandedEngagement && parent.id != focusedNoteId) {
                            perNoteEngagement[parent.id]?.let { details ->
                                ThreadNoteEngagementRow(
                                    details = details,
                                    onClick = { kind -> engagementSheet = EngagementSheetTarget(kind, parent.id) },
                                    modifier = Modifier.padding(horizontal = ThreadSideInset),
                                )
                            }
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
                        profiles = profiles,
                        quotedNotes = remember(focusedNote!!.id, focusedNote!!.quotedEventIds, quotedNotesCache) {
                            focusedNote!!.quotedEventIds.mapNotNull { qid ->
                                viewModel.quotedNoteFor(qid)?.let { qid to it }
                            }.toMap()
                        },
                        stats = viewModel.statsFor(focusedNote!!.id),
                        engagement = engagementDetails,
                        isLiked = viewModel.isLiked(focusedNote!!.id),
                        isReposted = viewModel.isReposted(focusedNote!!.effectiveEventId),
                        isOwnNote = viewModel.isOwnNote(focusedNote!!.pubkey),
                        isFollowing = viewModel.isFollowing(focusedNote!!.pubkey),
                        themeColor = colors.primary,
                        onProfileClick = onProfileClick,
                        onNoteClick = onNoteClick,
                        onArticleClick = onArticleClick,
                        onLike = { viewModel.likeNote(focusedNote!!.effectiveEventId) },
                        onLongPressLike = { emojiTargetNote = focusedNote },
                        onRepost = { viewModel.repostNote(focusedNote!!.effectiveEventId) },
                        onQuote = { onQuote(focusedNote!!.effectiveEventId) },
                        onReply = { onReply(focusedNote!!.effectiveEventId) },
                        onFollow = { viewModel.followUser(focusedNote!!.pubkey) },
                        onUnfollow = { viewModel.unfollowUser(focusedNote!!.pubkey) },
                        onBlock = { blockTarget = focusedNote },
                        onDelete = { deleteTarget = focusedNote },
                        onReport = { reportTarget = focusedNote },
                        onReactionsClick = { engagementSheet = EngagementSheetTarget(EngagementSheetKind.REACTIONS, null) },
                        onRepostsClick = { engagementSheet = EngagementSheetTarget(EngagementSheetKind.REPOSTS, null) },
                        onZapsClick = { engagementSheet = EngagementSheetTarget(EngagementSheetKind.ZAPS, null) },
                        onZap = { zapTargetNote = focusedNote },
                        onShare = { shareNote(context, focusedNote!!) },
                        onBroadcast = { broadcastTargetNote = focusedNote },
                    )
                }

                // ── Replies: loading / empty / header ───────────
                if (isLoadingReplies && directReplies.isEmpty()) {
                    item(key = "replies_loading") {
                        InlineLoadingRow(text = "Loading replies…", color = colors.primary)
                    }
                } else if (directReplies.isEmpty()) {
                    if (threadReplies.outside == 0) item(key = "replies_empty") {
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
                // Condensed: one card of lines, nested under what they answer;
                // tap a line and it becomes the note you are reading, full size.
                if (condensedReplies) {
                    val tree = FeedThreadGrouping.replyTree(replyTargetId, visibleReplies)
                    if (tree.isNotEmpty()) {
                        item(key = "replies_condensed") {
                            CondensedThreadCard {
                                for (entry in tree) {
                                    ThreadCondensedLine(
                                        note = entry.note,
                                        depth = entry.depth,
                                        replyCount = visibleReplies.count { it.parentEventId == entry.note.id },
                                        viewModel = viewModel,
                                        profiles = profiles,
                                        onProfileClick = onProfileClick,
                                        onTap = { scrollToNote(entry.note.id) },
                                    )
                                }
                            }
                        }
                    }
                } else items(directReplies, key = { it.id }) { reply ->
                    ThreadedReplyNode(
                        reply = reply,
                        pool = visibleReplies,
                        depth = 1,
                        focusedNoteId = focusedNoteId,
                        themeColor = colors.primary,
                        viewModel = viewModel,
                        expandedEngagement = expandedEngagement,
                        perNoteEngagement = perNoteEngagement,
                        profiles = profiles,
                        onProfileClick = onProfileClick,
                        onNoteClick = onNoteClick,
                        onArticleClick = onArticleClick,
                        onFocus = { id -> scrollToNote(id) },
                        onReply = onReply,
                        onQuote = onQuote,
                        onZapNote = { zapTargetNote = it },
                        onBroadcastNote = { broadcastTargetNote = it },
                        onModerateNote = { note, action ->
                            when (action) {
                                Moderation.REPORT -> reportTarget = note
                                Moderation.BLOCK -> blockTarget = note
                                Moderation.DELETE -> deleteTarget = note
                            }
                        },
                        onLongPressLikeNote = { emojiTargetNote = it },
                        onEngagementClick = { kind, id -> engagementSheet = EngagementSheetTarget(kind, id) },
                        modifier = Modifier.padding(horizontal = ThreadSideInset),
                    )
                }

                // Replies from outside your network, folded until asked for.
                if (!isLoadingReplies && threadReplies.outside > 0) {
                    item(key = "outside_replies") {
                        val count = threadReplies.outside
                        Row(
                            verticalAlignment = Alignment.CenterVertically,
                            horizontalArrangement = Arrangement.Center,
                            modifier = Modifier
                                .fillMaxWidth()
                                .clickable { showsOutsideReplies = true }
                                .padding(horizontal = 16.dp, vertical = 12.dp),
                        ) {
                            Icon(
                                NostrVaultIcons.PeopleOutline,
                                contentDescription = null,
                                tint = SecondaryText,
                                modifier = Modifier.size(14.dp),
                            )
                            Spacer(Modifier.width(6.dp))
                            Text(
                                text = if (count == 1) "Show 1 reply from outside your network"
                                else "Show $count replies from outside your network",
                                color = SecondaryText,
                                fontSize = 13.sp,
                                fontWeight = FontWeight.SemiBold,
                            )
                        }
                    }
                }

                // ── Quotes & highlights (below the fold) ─────────
                if (otherResponses.isNotEmpty()) {
                    item(key = "other_header") {
                        Text(
                            text = "Quotes & highlights",
                            color = PrimaryText,
                            fontSize = 15.sp,
                            fontWeight = FontWeight.Bold,
                            modifier = Modifier.padding(start = 16.dp, end = 16.dp, top = 20.dp, bottom = 8.dp),
                        )
                    }
                    items(otherResponses, key = { "other_${it.id}" }) { response ->
                        OtherResponseCard(
                            note = response,
                            profile = profiles[response.pubkey],
                            onClick = { if (response.kind == 1) onNoteClick(response.id) },
                        )
                    }
                }

                // Bottom spacer, and room under a short thread so the opened
                // note can scroll to the top with the posts it answers above
                // it. Without it a reply with few replies of its own stayed at
                // the bottom of the screen: there was nothing below to scroll into.
                item(key = "bottom_room") {
                    val room = if (shownParents.isNotEmpty()) {
                        with(density) { viewportHeight.toDp() - 200.dp }.coerceAtLeast(32.dp)
                    } else {
                        32.dp
                    }
                    Spacer(Modifier.height(room))
                }
            }
            }
        }
    }

    // ── Bottom sheets ────────────────────────────────────────────
    engagementSheet?.let { target ->
        val details = if (target.noteId == null) engagementDetails else perNoteEngagement[target.noteId]
        if (target.noteId != null) {
            LaunchedEffect(target) { details?.let(viewModel::fetchEngagementProfiles) }
        }
        val dismiss = { engagementSheet = null }
        when (target.kind) {
            EngagementSheetKind.REACTIONS -> ReactorsSheet(
                reactions = details?.reactions ?: emptyList(),
                profiles = profiles,
                onProfileClick = onProfileClick,
                onDismiss = dismiss,
            )
            EngagementSheetKind.ZAPS -> ZappersSheet(
                zaps = details?.zaps ?: emptyList(),
                profiles = profiles,
                onProfileClick = onProfileClick,
                onDismiss = dismiss,
            )
            EngagementSheetKind.REPOSTS -> RepostersSheet(
                reposts = details?.reposts ?: emptyList(),
                profiles = profiles,
                onProfileClick = onProfileClick,
                onDismiss = dismiss,
            )
        }
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
            .padding(start = ThreadSideInset + 36.dp)
            .width(1.5.dp)
            .height(12.dp)
            .background(color.copy(alpha = 0.25f)),
    )
}

// ── Threaded reply node (recursive) ─────────────────────────────
// Matches iOS ThreadedReplyNode: recursive tree rendering with depth-based
// collapsing, focus highlight, and thread connector lines. This is the full
// mode; the condensed toggle swaps the replies for ThreadCondensedLine rows.

/**
 * What a reply's overflow menu asked for. One parameter through the recursive
 * reply tree instead of three, and the confirmation dialogs stay at screen
 * level where they already are.
 */
internal enum class Moderation { REPORT, BLOCK, DELETE }

private const val COLLAPSE_DEPTH = 3

private const val THREAD_PREFS = "thread_view"
private const val KEY_CONDENSED_REPLIES = "condensedReplies"

/**
 * The thread view's condensed mode: one card of lines, drawn the way the
 * threaded feed draws a conversation ([FeedThreadCard]). iOS: `.threadCard()`.
 */
@Composable
private fun CondensedThreadCard(content: @Composable ColumnScope.() -> Unit) {
    val isOled = LocalOledMode.current
    val themeColor = LocalNostrVaultColors.current.primary
    Column(
        verticalArrangement = Arrangement.spacedBy(2.dp),
        modifier = Modifier
            .fillMaxWidth()
            .padding(horizontal = 10.dp, vertical = 4.dp)
            .background(SecondaryGroupedBg, RoundedCornerShape(12.dp))
            .border(
                width = if (isOled) 1.dp else 0.5.dp,
                color = themeColor.copy(alpha = if (isOled) 0.30f else 0.15f),
                shape = RoundedCornerShape(12.dp),
            )
            .padding(vertical = 8.dp, horizontal = 6.dp),
        content = content,
    )
}

/**
 * One condensed line, as the threaded feed draws it: a bare repost shows the
 * note it carries, credited to its author. iOS: `NoteDetailView.condensedLine`.
 */
@Composable
private fun ThreadCondensedLine(
    note: FeedNote,
    depth: Int,
    replyCount: Int,
    viewModel: NoteDetailViewModel,
    profiles: Map<String, FeedProfile>,
    onProfileClick: (String) -> Unit,
    onTap: () -> Unit,
) {
    val original = note.repostedEventId?.takeIf { note.isBareRepost }
        ?.let(viewModel::findNote)?.takeIf { it.kind != 6 }
    val shown = original?.let { note.withRepostedOriginal(it) } ?: note
    val stats = viewModel.statsFor(note.id)
    CondensedNoteLine(
        note = shown,
        profile = viewModel.profileFor(shown.pubkey),
        profiles = profiles,
        depth = depth,
        style = CondensedLineStyle.PLAIN,
        replyCount = replyCount,
        mediaURLs = shown.mediaURLs,
        engagement = CondensedEngagement(
            reactions = if (LocalZapsOnlyMode.current) 0 else stats?.reactions ?: 0,
            reposts = stats?.reposts ?: 0,
        ),
        onProfileClick = onProfileClick,
        onTap = onTap,
    )
}

@Composable
private fun ThreadedReplyNode(
    reply: FeedNote,
    /** The replies the thread shows (blocked, spam and folded ones already out). */
    pool: List<FeedNote>,
    depth: Int,
    focusedNoteId: String,
    themeColor: androidx.compose.ui.graphics.Color,
    viewModel: NoteDetailViewModel,
    expandedEngagement: Boolean,
    perNoteEngagement: Map<String, EngagementDetails>,
    profiles: Map<String, FeedProfile>,
    onProfileClick: (String) -> Unit,
    onNoteClick: (String) -> Unit,
    /** Where a quoted long-form post opens; the note screen would show its Markdown source. */
    onArticleClick: (String) -> Unit,
    onFocus: (String) -> Unit,
    onReply: (String) -> Unit,
    onQuote: (String) -> Unit,
    onZapNote: (FeedNote) -> Unit,
    onBroadcastNote: (FeedNote) -> Unit,
    onModerateNote: (FeedNote, Moderation) -> Unit,
    onLongPressLikeNote: (FeedNote) -> Unit,
    /** A pill in a note's engagement row: open that list for that note. */
    onEngagementClick: (EngagementSheetKind, String) -> Unit,
    modifier: Modifier = Modifier,
) {
    // Keyed on the pool too: late-arriving replies (refocus fetch,
    // pull-to-refresh) must recompute each node's children.
    val childReplies = remember(reply.id, pool) { pool.filter { it.parentEventId == reply.id } }
    val isFocusedReply = reply.id == focusedNoteId
    val quotedNotesCache by viewModel.quotedNotesCache.collectAsState()
    val quotedNotesMap = remember(reply.id, reply.quotedEventIds, quotedNotesCache) {
        reply.quotedEventIds.mapNotNull { qid ->
            viewModel.quotedNoteFor(qid)?.let { qid to it }
        }.toMap()
    }

    Column(
        modifier = modifier.animateContentSize(animationSpec = Motion.panel()),
    ) {
        // The reply itself
        NoteCard(
            note = reply,
            profile = viewModel.profileFor(reply.pubkey),
            profiles = profiles,
            quotedNotes = quotedNotesMap,
            isLiked = viewModel.isLiked(reply.id),
            isReposted = viewModel.isReposted(reply.effectiveEventId),
            isFocused = isFocusedReply,
            onNoteClick = { onFocus(reply.id) },
            onArticleClick = onArticleClick,
            onProfileClick = onProfileClick,
            onLike = viewModel::likeNote,
            onRepost = viewModel::repostNote,
            onQuote = onQuote,
            onReply = onReply,
            onZap = { onZapNote(reply) },
            onBroadcast = { onBroadcastNote(reply) },
            isOwnNote = viewModel.isOwnNote(reply.pubkey),
            onReport = { onModerateNote(reply, Moderation.REPORT) },
            onBlock = { onModerateNote(reply, Moderation.BLOCK) },
            onDelete = { onModerateNote(reply, Moderation.DELETE) },
            onLongPressLike = { onLongPressLikeNote(reply) },
        )

        // Per-note engagement when thread stats are on: emoji pills, zap
        // sats and reposts, each opening its list (iOS ThreadNoteEngagementRow).
        // The focused one is left out, as on iOS: the hero card shows it.
        // Data is the thread's one batch fetch, nothing per row.
        if (expandedEngagement && !isFocusedReply) {
            perNoteEngagement[reply.id]?.let { details ->
                ThreadNoteEngagementRow(
                    details = details,
                    onClick = { kind -> onEngagementClick(kind, reply.id) },
                )
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
                // Render children with connector line (matches iOS HStack + Rectangle).
                // Drawn behind the column, not as a fillMaxHeight sibling: that
                // needed an intrinsic-height pass through every nested note.
                Column(
                    verticalArrangement = Arrangement.spacedBy(8.dp),
                    modifier = Modifier
                        .padding(start = 8.dp)
                        .drawBehind {
                            val inset = 2.dp.toPx()
                            drawRect(
                                color = themeColor.copy(alpha = 0.25f),
                                topLeft = Offset(0f, inset),
                                size = Size(1.5.dp.toPx(), (size.height - 2 * inset).coerceAtLeast(0f)),
                            )
                        }
                        .padding(start = 7.5.dp),
                ) {
                    for (child in childReplies) {
                        ThreadedReplyNode(
                            reply = child,
                            pool = pool,
                            depth = depth + 1,
                            focusedNoteId = focusedNoteId,
                            themeColor = themeColor,
                            viewModel = viewModel,
                            expandedEngagement = expandedEngagement,
                            perNoteEngagement = perNoteEngagement,
                            profiles = profiles,
                            onProfileClick = onProfileClick,
                            onNoteClick = onNoteClick,
                            onArticleClick = onArticleClick,
                            onFocus = onFocus,
                            onReply = onReply,
                            onQuote = onQuote,
                            onZapNote = onZapNote,
                            onBroadcastNote = onBroadcastNote,
                            onModerateNote = onModerateNote,
                            onLongPressLikeNote = onLongPressLikeNote,
                            onEngagementClick = onEngagementClick,
                        )
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
    profiles: Map<String, FeedProfile> = emptyMap(),
    /** Quoted events keyed by the lookup key `note.quotedEventIds` holds. */
    quotedNotes: Map<String, FeedNote> = emptyMap(),
    stats: NoteStats?,
    /** Who reacted with what and each zap's amount, for the engagement row. */
    engagement: EngagementDetails? = null,
    isLiked: Boolean,
    isReposted: Boolean = false,
    isOwnNote: Boolean,
    isFollowing: Boolean,
    themeColor: androidx.compose.ui.graphics.Color,
    onProfileClick: (String) -> Unit,
    onNoteClick: (String) -> Unit,
    onArticleClick: (String) -> Unit,
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
    var showMoreMenu by remember { mutableStateOf(false) }
    val heroContext = LocalContext.current
    val heroClipboard = LocalClipboardManager.current
    val cardShape = RoundedCornerShape(12.dp)

    // iOS mainNoteLayout: the same card as a focused feed row — 14pt padding,
    // a 2pt accent border and an accent-tinted glow (opacity 0.35, radius 8),
    // 16pt in from the screen edges. The glow is the accent, not a grey
    // elevation shadow, and the surface is opaque so it does not show through.
    Surface(
        color = SecondaryGroupedBg,
        shape = cardShape,
        border = androidx.compose.foundation.BorderStroke(2.dp, themeColor),
        modifier = Modifier
            .fillMaxWidth()
            .padding(horizontal = 16.dp, vertical = 4.dp)
            .shadow(
                elevation = 8.dp,
                shape = cardShape,
                ambientColor = themeColor.copy(alpha = 0.35f),
                spotColor = themeColor.copy(alpha = 0.35f),
            ),
    ) {
        Column(
            modifier = Modifier
                .background(themeColor.copy(alpha = HERO_TINT_ALPHA))
                .padding(14.dp),
        ) {
            // Author header, iOS `.wide` row: 40pt avatar, name with the
            // NIP-05 seal, relative time on the right, "reply to" under it.
            Row(
                verticalAlignment = Alignment.CenterVertically,
                modifier = Modifier.fillMaxWidth(),
            ) {
                AvatarImage(
                    url = profile?.pictureURL,
                    pubkey = note.pubkey,
                    size = 40.dp,
                    displayName = profile?.bestName,
                    modifier = Modifier.clickable { onProfileClick(note.pubkey) },
                )
                Spacer(Modifier.width(12.dp))
                Column(
                    verticalArrangement = Arrangement.spacedBy(2.dp),
                    modifier = Modifier.weight(1f),
                ) {
                    Row(verticalAlignment = Alignment.CenterVertically) {
                        Text(
                            text = profile?.bestName ?: note.pubkey.take(8) + "...",
                            color = PrimaryText,
                            fontSize = 14.sp,
                            fontWeight = FontWeight.SemiBold,
                            maxLines = 1,
                            overflow = TextOverflow.Ellipsis,
                            modifier = Modifier
                                .weight(1f, fill = false)
                                .clickable { onProfileClick(note.pubkey) },
                        )
                        if (!profile?.nip05.isNullOrBlank()) {
                            Spacer(Modifier.width(6.dp))
                            Icon(
                                imageVector = NostrVaultIcons.Verified,
                                contentDescription = "Verified",
                                tint = androidx.compose.ui.graphics.Color(0xFF33CC99),
                                modifier = Modifier.size(14.dp),
                            )
                        }
                        if (note.isFromNostrVault) {
                            Spacer(Modifier.width(6.dp))
                            NostrVaultBadge(size = 12.dp)
                        }
                        Spacer(Modifier.weight(1f))
                        Text(
                            text = formatTimestamp(note.postedAt.time / 1000),
                            color = SecondaryText,
                            fontSize = 11.sp,
                            fontFamily = FontFamily.Monospace,
                            letterSpacing = 0.2.sp,
                        )
                    }
                    val replyToPubkey = note.replyToPubkey
                    if (note.isReply && replyToPubkey != null) {
                        Row(verticalAlignment = Alignment.CenterVertically) {
                            Icon(
                                imageVector = NostrVaultIcons.Reply,
                                contentDescription = null,
                                tint = themeColor.copy(alpha = 0.6f),
                                modifier = Modifier.size(10.dp),
                            )
                            Spacer(Modifier.width(3.dp))
                            Text(
                                text = "reply to ${profiles[replyToPubkey]?.bestName ?: replyToPubkey.take(8) + "..."}",
                                color = SecondaryText.copy(alpha = 0.7f),
                                fontSize = 10.sp,
                                fontFamily = FontFamily.Monospace,
                                letterSpacing = 0.1.sp,
                                maxLines = 1,
                                overflow = TextOverflow.Ellipsis,
                            )
                        }
                    }
                }

                // More menu button. Same component as every other note's menu —
                // this one carries Follow/Unfollow as well, because the focused
                // note is the only place that offers them.
                Box {
                    IconButton(onClick = { showMoreMenu = true }) {
                        Icon(NostrVaultIcons.More, "More", tint = SecondaryText, modifier = Modifier.size(18.dp))
                    }
                    NoteActionsMenu(
                        expanded = showMoreMenu,
                        actions = buildList {
                            add(NoteAction(NostrVaultIcons.Share, "Share", onClick = onShare))
                            add(
                                NoteAction(NostrVaultIcons.LinkIcon, "Copy link") {
                                    val nevent = HavenBridge.encodeNevent(
                                        note.effectiveEventId,
                                        note.pubkey,
                                        note.kind,
                                    ) ?: HavenBridge.hexToNote1(note.effectiveEventId)
                                        ?: note.effectiveEventId
                                    heroClipboard.setText(AnnotatedString(threadLink(nevent)))
                                    Toast.makeText(heroContext, "Link copied", Toast.LENGTH_SHORT).show()
                                },
                            )
                            add(NoteAction(NostrVaultIcons.Relay, "Broadcast", onClick = onBroadcast))
                            if (isOwnNote) {
                                add(NoteAction(NostrVaultIcons.Delete, "Delete Post", destructive = true, onClick = onDelete))
                            } else {
                                if (isFollowing) {
                                    add(NoteAction(NostrVaultIcons.Blocked, "Unfollow", onClick = onUnfollow))
                                } else {
                                    add(NoteAction(NostrVaultIcons.PersonAdd, "Follow", onClick = onFollow))
                                }
                                // Same names and order as the feed's ⋯ menu.
                                add(NoteAction(NostrVaultIcons.Alert, "Report Post", destructive = true, onClick = onReport))
                                add(NoteAction(NostrVaultIcons.Blocked, "Block User", destructive = true, onClick = onBlock))
                            }
                        },
                        onDismiss = { showMoreMenu = false },
                    )
                }
            }

            Spacer(Modifier.height(10.dp))

            // Content
            if (note.content.isNotBlank()) {
                val mediaSet = remember(note.mediaURLs) { note.mediaURLs.toSet() }
                val linkSet = remember(note.cardLinkURLs) { note.cardLinkURLs.toSet() }
                TranslatableNoteText(
                    noteKey = note.effectiveEventId,
                    content = note.content,
                    profiles = profiles,
                    mediaURLs = mediaSet,
                    linkURLs = linkSet,
                    fontSize = 17.sp,
                    lineHeight = 24.sp,
                ) {
                    NostrContentText(
                        content = note.content,
                        profiles = profiles,
                        mediaURLs = mediaSet,
                        linkURLs = linkSet,
                        onProfileClick = onProfileClick,
                        fontSize = 17.sp,
                        lineHeight = 24.sp,
                    )
                }
                Spacer(Modifier.height(12.dp))
            }

            // One card per link: the URLs are out of the text above (#170).
            for (link in note.cardLinkURLs) {
                LinkPreviewCard(url = link)
                Spacer(Modifier.height(12.dp))
            }

            // Media
            if (note.mediaURLs.isNotEmpty()) {
                MediaPreviewRow(urls = note.mediaURLs, tags = note.tags)
                Spacer(Modifier.height(12.dp))
            }

            // Quoted events. The reference itself is stripped out of the text
            // above, so without this the focused note silently loses whatever
            // it was quoting — on the one screen opened to read it in full.
            for (qid in note.quotedEventIds) {
                val quoted = quotedNotes[qid]
                if (quoted != null) {
                    QuotedNoteCard(
                        note = quoted,
                        profile = profiles[quoted.pubkey],
                        profiles = profiles,
                        onClick = onNoteClick,
                        onArticleClick = onArticleClick,
                    )
                } else {
                    QuotedNotePlaceholder(identifier = qid, onClick = onNoteClick)
                }
                Spacer(Modifier.height(12.dp))
            }

            // The time is in the header, relative, as on iOS — the card no
            // longer repeats it as a full date under the body.
            HorizontalDivider(color = SeparatorColor, thickness = 0.5.dp)

            // Engagement row — only shown when at least one count is non-zero.
            // Reactions as per-emoji pills, zaps as "count · total sats", the
            // way iOS shows them. The per-event details arrive after the
            // counts, so the counts stand in until then. Reactions are dropped
            // entirely in Zaps Only mode.
            val zapsOnly = LocalZapsOnlyMode.current
            val emojiGroups = remember(engagement?.reactions, stats?.reactions, zapsOnly) {
                when {
                    zapsOnly -> emptyList()
                    !engagement?.reactions.isNullOrEmpty() -> EngagementSummary.groupReactions(engagement!!.reactions)
                    (stats?.reactions ?: 0) > 0 -> listOf(EngagementSummary.EmojiGroup("\u2764\uFE0F", stats!!.reactions))
                    else -> emptyList()
                }
            }
            val reposts = engagement?.reposts?.map { it.pubkey }?.distinct()?.size?.takeIf { it > 0 }
                ?: stats?.reposts ?: 0
            val zapDetails = engagement?.zaps.orEmpty()
            val zapCount = if (zapDetails.isNotEmpty()) zapDetails.size else stats?.zaps ?: 0
            val zapSats = if (zapDetails.isNotEmpty()) zapDetails.sumOf { it.amountSats } else stats?.zapAmountSats ?: 0L
            if (emojiGroups.isNotEmpty() || reposts > 0 || zapCount > 0) {
                Spacer(Modifier.height(12.dp))
                Row(
                    horizontalArrangement = Arrangement.spacedBy(12.dp),
                    verticalAlignment = Alignment.CenterVertically,
                    modifier = Modifier.fillMaxWidth(),
                ) {
                    if (emojiGroups.isNotEmpty()) {
                        val shown = emojiGroups.take(EngagementSummary.VISIBLE_EMOJI_GROUPS)
                        EngagementPill(
                            description = emojiGroups.joinToString(prefix = "Reactions: ") { "${it.emoji} ${it.count}" },
                            onClick = onReactionsClick,
                        ) {
                            shown.forEach { group ->
                                Text(group.emoji, fontSize = 12.sp)
                                Spacer(Modifier.width(2.dp))
                                Text("${group.count}", color = SecondaryText, fontSize = 10.sp, fontWeight = FontWeight.Bold, fontFamily = FontFamily.Monospace)
                                Spacer(Modifier.width(4.dp))
                            }
                            if (emojiGroups.size > shown.size) {
                                Text("+${emojiGroups.size - shown.size}", color = SecondaryText, fontSize = 10.sp, fontWeight = FontWeight.Bold, fontFamily = FontFamily.Monospace)
                            }
                        }
                    }
                    if (zapCount > 0) {
                        val text = EngagementSummary.zapText(zapCount, zapSats)
                        EngagementPill(description = "Zaps: $text sats", onClick = onZapsClick) {
                            Icon(NostrVaultIcons.Zap, contentDescription = null, tint = ZapOrange, modifier = Modifier.size(12.dp))
                            Spacer(Modifier.width(4.dp))
                            Text(text, color = SecondaryText, fontSize = 11.sp, fontWeight = FontWeight.SemiBold, fontFamily = FontFamily.Monospace)
                        }
                    }
                    if (reposts > 0) {
                        EngagementPill(description = "Reposts: $reposts", onClick = onRepostsClick) {
                            Icon(NostrVaultIcons.Repost, contentDescription = null, tint = RepostGreen, modifier = Modifier.size(12.dp))
                            Spacer(Modifier.width(4.dp))
                            Text("$reposts", color = SecondaryText, fontSize = 11.sp, fontWeight = FontWeight.SemiBold, fontFamily = FontFamily.Monospace)
                        }
                    }
                }
                Spacer(Modifier.height(12.dp))
                HorizontalDivider(color = SeparatorColor, thickness = 0.5.dp)
            }

            Spacer(Modifier.height(8.dp))

            // Action buttons. The real `EngagementBar`, not a copy of it — this
            // was a hand-duplicated seven-button row under a comment claiming it
            // was identical, which is how it kept Share and Broadcast inline
            // while every other note on this screen had moved them to the menu.
            EngagementBar(
                noteId = note.effectiveEventId,
                isLiked = isLiked,
                isZapped = false,
                isReposted = isReposted,
                onReply = { onReply() },
                onRepost = { onRepost() },
                onQuote = { onQuote() },
                onLike = { onLike() },
                onZap = { onZap() },
                onLongPressLike = { onLongPressLike() },
            )
        }
    }
}

/**
 * One tappable pill in an engagement row: the hero note's, or with [compact]
 * the smaller one under each note in the thread (iOS ThreadNoteEngagementRow:
 * 6x3 padding, 6pt corners, white at 0.04).
 */
@Composable
private fun EngagementPill(
    description: String,
    onClick: () -> Unit,
    compact: Boolean = false,
    content: @Composable RowScope.() -> Unit,
) {
    Row(
        verticalAlignment = Alignment.CenterVertically,
        modifier = Modifier
            .clip(RoundedCornerShape(if (compact) 6.dp else 8.dp))
            .background(androidx.compose.ui.graphics.Color.White.copy(alpha = if (compact) 0.04f else 0.05f))
            .clickable(onClick = onClick)
            .semantics(mergeDescendants = true) { contentDescription = description }
            .padding(horizontal = if (compact) 6.dp else 8.dp, vertical = if (compact) 3.dp else 5.dp),
        content = content,
    )
}

/** Which engagement list a pill opens. */
private enum class EngagementSheetKind { REACTIONS, ZAPS, REPOSTS }

/** An open engagement sheet: which list, and for which note (null: the focused one). */
private data class EngagementSheetTarget(val kind: EngagementSheetKind, val noteId: String?)

/**
 * Under a parent or reply in the thread when thread stats are on: a hairline,
 * then emoji pills (three, then "+N"), zap sats and reposts, each pill opening
 * its list. iOS ThreadNoteEngagementRow. Draws nothing for a note with none.
 */
@Composable
private fun ThreadNoteEngagementRow(
    details: EngagementDetails,
    onClick: (EngagementSheetKind) -> Unit,
    modifier: Modifier = Modifier,
) {
    val zapsOnly = LocalZapsOnlyMode.current
    val row = remember(details, zapsOnly) { EngagementSummary.threadRow(details, zapsOnly) }
    if (row.isEmpty) return
    Column(modifier = modifier.padding(horizontal = 12.dp)) {
        HorizontalDivider(
            color = SecondaryText.copy(alpha = 0.1f),
            thickness = 0.5.dp,
            modifier = Modifier.padding(top = 8.dp),
        )
        Row(
            horizontalArrangement = Arrangement.spacedBy(8.dp),
            verticalAlignment = Alignment.CenterVertically,
            modifier = Modifier.padding(top = 4.dp, bottom = 8.dp),
        ) {
            if (row.emojiGroups.isNotEmpty()) {
                val shown = row.emojiGroups.take(EngagementSummary.THREAD_ROW_EMOJI_GROUPS)
                EngagementPill(
                    description = row.emojiGroups.joinToString(prefix = "Reactions: ") { "${it.emoji} ${it.count}" },
                    onClick = { onClick(EngagementSheetKind.REACTIONS) },
                    compact = true,
                ) {
                    shown.forEachIndexed { index, group ->
                        if (index > 0) Spacer(Modifier.width(3.dp))
                        Text(group.emoji, fontSize = 11.sp)
                        Spacer(Modifier.width(1.dp))
                        Text("${group.count}", color = SecondaryText, fontSize = 9.sp, fontWeight = FontWeight.Bold, fontFamily = FontFamily.Monospace)
                    }
                    if (row.emojiGroups.size > shown.size) {
                        Spacer(Modifier.width(3.dp))
                        Text("+${row.emojiGroups.size - shown.size}", color = SecondaryText, fontSize = 9.sp, fontWeight = FontWeight.Bold, fontFamily = FontFamily.Monospace)
                    }
                }
            }
            if (row.zapCount > 0) {
                val sats = EngagementSummary.satsText(row.zapSats)
                EngagementPill(
                    description = "Zaps: ${row.zapCount}, $sats sats",
                    onClick = { onClick(EngagementSheetKind.ZAPS) },
                    compact = true,
                ) {
                    Icon(NostrVaultIcons.Zap, contentDescription = null, tint = ZapOrange, modifier = Modifier.size(9.dp))
                    Spacer(Modifier.width(2.dp))
                    Text(sats, color = SecondaryText, fontSize = 9.sp, fontWeight = FontWeight.SemiBold, fontFamily = FontFamily.Monospace)
                }
            }
            if (row.reposts > 0) {
                EngagementPill(
                    description = "Reposts: ${row.reposts}",
                    onClick = { onClick(EngagementSheetKind.REPOSTS) },
                    compact = true,
                ) {
                    Icon(NostrVaultIcons.Repost, contentDescription = null, tint = RepostGreen, modifier = Modifier.size(9.dp))
                    Spacer(Modifier.width(2.dp))
                    Text("${row.reposts}", color = SecondaryText, fontSize = 9.sp, fontWeight = FontWeight.SemiBold, fontFamily = FontFamily.Monospace)
                }
            }
        }
    }
}

/** One "below the fold" response: who, what kind, and the text. */
@Composable
private fun OtherResponseCard(note: FeedNote, profile: FeedProfile?, onClick: () -> Unit) {
    val label = when (note.kind) {
        1 -> "Quoted"
        9802 -> "Highlighted"
        1244 -> "Voice reply"
        else -> "Responded"
    }
    Column(
        modifier = Modifier
            .fillMaxWidth()
            .padding(horizontal = 16.dp, vertical = 4.dp)
            .clip(RoundedCornerShape(12.dp))
            .background(SecondaryText.copy(alpha = 0.08f))
            .clickable(enabled = note.kind == 1, onClick = onClick)
            .padding(12.dp),
    ) {
        Row(verticalAlignment = Alignment.CenterVertically) {
            AvatarImage(url = profile?.pictureURL, pubkey = note.pubkey, size = 22.dp, displayName = profile?.bestName)
            Spacer(Modifier.width(8.dp))
            Text(
                text = profile?.bestName ?: note.pubkey.take(8),
                color = PrimaryText, fontSize = 13.sp, fontWeight = FontWeight.SemiBold, maxLines = 1,
            )
            Spacer(Modifier.width(8.dp))
            Text(label, color = SecondaryText, fontSize = 11.sp, fontWeight = FontWeight.SemiBold)
        }
        if (note.content.isNotBlank()) {
            Spacer(Modifier.height(6.dp))
            Text(
                text = note.content,
                color = PrimaryText,
                fontSize = 14.sp,
                maxLines = if (note.kind == 9802) 6 else 4,
                overflow = TextOverflow.Ellipsis,
                fontStyle = if (note.kind == 9802) FontStyle.Italic else FontStyle.Normal,
            )
        }
    }
}

/**
 * The focused card's accent wash. iOS lays havenPurple at 0.015 over an opaque
 * card; 0.04 is what the focused [NoteCard] uses on Android, so the hero and a
 * focused reply read as the same card.
 */
private const val HERO_TINT_ALPHA = 0.04f

/**
 * Parents and replies sit this far in from the screen's edges, lined up with
 * the focused card (iOS pads both .horizontal 16).
 */
private val ThreadSideInset = 16.dp

/** Where the opened note lands in the thread view, as a share of its height from the top (iOS #306). */
private const val THREAD_LANDING_ANCHOR = 0.12f
