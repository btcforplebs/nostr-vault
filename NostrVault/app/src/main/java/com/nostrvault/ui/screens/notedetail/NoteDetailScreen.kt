package com.nostrvault.ui.screens

import androidx.compose.foundation.ExperimentalFoundationApi
import androidx.compose.foundation.clickable
import androidx.compose.foundation.interaction.DragInteraction
import androidx.compose.foundation.layout.*
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.items
import androidx.compose.foundation.lazy.rememberLazyListState
import androidx.compose.material3.*
import androidx.compose.material3.pulltorefresh.PullToRefreshBox
import androidx.compose.runtime.*
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.platform.LocalDensity
import androidx.compose.ui.semantics.contentDescription
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import androidx.hilt.navigation.compose.hiltViewModel
import com.nostrvault.data.model.*
import com.nostrvault.service.FeedFilterEngine
import com.nostrvault.ui.components.*
import com.nostrvault.ui.theme.*
import kotlinx.coroutines.flow.*
import java.util.*

/**
 * Thread view for a single note with parent chain, nested replies,
 * tap-to-focus navigation, and depth-based collapsing.
 * Port of NoteDetailView.swift.
 */

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
    // The post bar's Web of Trust button: the author whose map is open.
    var trustWebAuthor by remember { mutableStateOf<String?>(null) }
    val openTrustWeb: (String) -> Unit = { author -> trustWebAuthor = author }
    val broadcastSheetState = rememberModalBottomSheetState(skipPartiallyExpanded = true)

    // Moderation confirmations. These hold the note they were opened for rather
    // than a flag, because the overflow menu is now on every note on this screen
    // and not only on the focused one. Acting on the focused note still leaves
    // the screen — there is nothing left to look at; acting on a reply does not.
    var deleteTarget by remember { mutableStateOf<FeedNote?>(null) }
    var blockTarget by remember { mutableStateOf<FeedNote?>(null) }
    var reportTarget by remember { mutableStateOf<FeedNote?>(null) }

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

    // Whether the note shown full size is by someone you blocked, read from
    // the live block list so a block made anywhere on this page applies at
    // once. iOS: NoteDetailView.focusedNoteBlockState (#676).
    val focusedBlockState = remember(focusedNote, focusedNoteId, blockedPubkeys) {
        focusedNote?.let { BlockedPeople.focusedNote(it.pubkey, isOpenedNote = focusedNoteId == noteId, blocked = blockedPubkeys) }
            ?: BlockedPeople.FocusedNote.SHOWN
    }
    val showsBlockedPlaceholder = focusedBlockState == BlockedPeople.FocusedNote.PLACEHOLDER

    // Blocked the author of the reply you tapped into: back to the note you
    // opened, as the reply itself is now hidden.
    LaunchedEffect(focusedBlockState) {
        if (focusedBlockState == BlockedPeople.FocusedNote.BACK_TO_OPENED) focusedNoteId = noteId
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
        BlockedPeople.visibleNotes(dynamicParents, blockedPubkeys) { it.pubkey }
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
    // The placeholder takes the opened note's replies and quotes with it.
    val visibleReplies = if (showsBlockedPlaceholder) emptyList() else threadReplies.visible
    val outsideReplies = if (showsBlockedPlaceholder) 0 else threadReplies.outside
    val shownResponses = remember(otherResponses, blockedPubkeys, showsBlockedPlaceholder) {
        if (showsBlockedPlaceholder) emptyList()
        else BlockedPeople.visibleNotes(otherResponses, blockedPubkeys) { it.pubkey }
    }

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
                        // Stays on the page: the opened note turns into a
                        // placeholder, a tapped-into reply hands focus back.
                        viewModel.blockUser(target.pubkey)
                        blockTarget = null
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
                    // Reply and Broadcast would act on the blocked note behind
                    // the placeholder, so they go with it (iOS 1d38f8be).
                    if (!showsBlockedPlaceholder) {
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
                                        onTrustWeb = openTrustWeb,
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
                            avatarMenu = viewModel.avatarMenu,
                            profile = viewModel.profileFor(parent.pubkey),
                            profiles = profiles,
                            quotedNotes = quotedNotesMap,
                            isLiked = viewModel.isLiked(parent.effectiveEventId),
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
                            onTrustWeb = if (viewModel.isOwnNote(parent.effectiveAuthor)) null else openTrustWeb,
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
                if (showsBlockedPlaceholder) item(key = "hero_blocked") {
                    BlockedNotePlaceholder(modifier = Modifier.padding(horizontal = ThreadSideInset))
                } else item(key = "hero_${focusedNote!!.id}") {
                    HeroNoteCard(
                        note = focusedNote!!,
                        profile = viewModel.profileFor(focusedNote!!.pubkey),
                        profiles = profiles,
                        quotedNotes = remember(focusedNote!!.id, focusedNote!!.quotedEventIds, quotedNotesCache) {
                            focusedNote!!.quotedEventIds.mapNotNull { qid ->
                                viewModel.quotedNoteFor(qid)?.let { qid to it }
                            }.toMap()
                        },
                        stats = viewModel.statsFor(focusedNote!!.effectiveEventId),
                        engagement = engagementDetails,
                        isLiked = viewModel.isLiked(focusedNote!!.effectiveEventId),
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
                        onTrustWeb = focusedNote!!.effectiveAuthor.let { author ->
                            if (viewModel.isOwnNote(author)) null else ({ openTrustWeb(author) })
                        },
                    )
                }

                // ── Replies: loading / empty / header ───────────
                if (showsBlockedPlaceholder) {
                    // Nothing under the placeholder: its replies went with it.
                } else if (isLoadingReplies && directReplies.isEmpty()) {
                    item(key = "replies_loading") {
                        InlineLoadingRow(text = "Loading replies…", color = colors.primary)
                    }
                } else if (directReplies.isEmpty()) {
                    if (outsideReplies == 0) item(key = "replies_empty") {
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
                                        onTrustWeb = openTrustWeb,
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
                        onTrustWeb = openTrustWeb,
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
                if (!isLoadingReplies && outsideReplies > 0) {
                    item(key = "outside_replies") {
                        val count = outsideReplies
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
                if (shownResponses.isNotEmpty()) {
                    item(key = "other_header") {
                        Text(
                            text = "Quotes & highlights",
                            color = PrimaryText,
                            fontSize = 15.sp,
                            fontWeight = FontWeight.Bold,
                            modifier = Modifier.padding(start = 16.dp, end = 16.dp, top = 20.dp, bottom = 8.dp),
                        )
                    }
                    items(shownResponses, key = { "other_${it.id}" }) { response ->
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
            defaultAmount = viewModel.configStoreRef.config.value.defaultZapAmount,
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
            onProfileClick = { broadcastTargetNote = null; onProfileClick(it) },
        )
    }

    trustWebAuthor?.let { author ->
        TrustWebDialog(
            author = author,
            initialPath = null,
            onProfileClick = onProfileClick,
            onDismiss = { trustWebAuthor = null },
        )
    }
}

private const val THREAD_PREFS = "thread_view"
private const val KEY_CONDENSED_REPLIES = "condensedReplies"

/**
 * Parents and replies sit this far in from the screen's edges, lined up with
 * the focused card (iOS pads both .horizontal 16).
 */
internal val ThreadSideInset = 16.dp

/** Where the opened note lands in the thread view, as a share of its height from the top (iOS #306). */
private const val THREAD_LANDING_ANCHOR = 0.12f
