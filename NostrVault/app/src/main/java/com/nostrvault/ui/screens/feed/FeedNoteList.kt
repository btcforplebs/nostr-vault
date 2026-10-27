package com.nostrvault.ui.screens.feed

import androidx.compose.foundation.layout.*
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.LazyListState
import androidx.compose.foundation.lazy.items
import androidx.compose.material3.*
import androidx.compose.runtime.*
import androidx.compose.runtime.snapshots.SnapshotStateMap
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.layout.onGloballyPositioned
import androidx.compose.ui.layout.positionInRoot
import androidx.compose.ui.platform.LocalDensity
import androidx.compose.ui.unit.Dp
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import com.nostrvault.data.model.FeedNote
import com.nostrvault.data.model.FeedProfile
import com.nostrvault.data.model.FeedThread
import com.nostrvault.ui.components.AvatarMenuActions
import com.nostrvault.ui.components.CondensedEngagement
import com.nostrvault.ui.components.CondensedQuoteActions
import com.nostrvault.ui.components.FeedThreadCard
import com.nostrvault.ui.components.NostrMentions
import com.nostrvault.ui.components.RankedCompactNoteCard
import com.nostrvault.ui.components.ThreadLineAnchor
import com.nostrvault.ui.components.rememberCondensedQuotes
import androidx.compose.ui.text.font.FontFamily
import androidx.compose.ui.text.font.FontWeight
import com.nostrvault.ui.theme.*

/**
 * The note list of the text feeds: threaded cards, or expanded and condensed rows (iOS FeedView's list).
 * State only the rows read ([feedThreadsState], [unavailableNoteIdsState], [expandedNote]) comes in as State, so a
 * change to it recomposes the rows here and not the whole FeedScreen; the list read it the same way when it lived
 * there.
 */
@Composable
internal fun FeedNoteList(
    viewModel: FeedViewModel,
    listState: LazyListState,
    padding: PaddingValues,
    meterLift: Dp,
    threadLineAnchor: ThreadLineAnchor,
    isThreaded: Boolean,
    feedThreadsState: State<List<FeedThread>>,
    notes: List<FeedNote>,
    isCompact: Boolean,
    allProfiles: Map<String, FeedProfile>,
    expandedNote: MutableState<String?>,
    threadFolds: SnapshotStateMap<String, Boolean>,
    unavailableNoteIdsState: State<Set<String>>,
    isLoadingMore: Boolean,
    feedAvatarMenu: AvatarMenuActions?,
    sheets: FeedSheetState,
    openProfile: (String) -> Unit,
    onNoteClick: (String) -> Unit,
    onArticleClick: (String) -> Unit,
    onReply: ((String) -> Unit)?,
    onQuote: ((String) -> Unit)?,
    onCompose: () -> Unit,
) {
    val feedThreads by feedThreadsState
    val unavailableNoteIds by unavailableNoteIdsState
    var expandedNoteId by expandedNote
    var zapNoteId by sheets::zapNoteId
    var showNoLightningAddress by sheets::showNoLightningAddress
    var deleteNoteId by sheets::deleteNoteId
    var reportNoteId by sheets::reportNoteId
    var blockNoteId by sheets::blockNoteId
    var emojiPickerNoteId by sheets::emojiPickerNoteId
    var broadcastNoteId by sheets::broadcastNoteId
    var trustWebAuthor by sheets::trustWebAuthor
    val density = LocalDensity.current
    // A condensed line's quote opens the quoted note, as the expanded row's does.
    val quoteActions = remember(viewModel, onNoteClick, onArticleClick) {
        CondensedQuoteActions(
            onOpen = onNoteClick,
            onArticleClick = onArticleClick,
            onMissing = { id -> viewModel.fetchMissingQuotedNotes(listOf(id)) },
        )
    }
    LazyColumn(
        state = listState,
        contentPadding = PaddingValues(
            top = padding.calculateTopPadding(),
            bottom = padding.calculateBottomPadding() + 88.dp + meterLift,
        ),
        modifier = Modifier
            .fillMaxSize()
            .onGloballyPositioned {
                threadLineAnchor.viewportTop = it.positionInRoot().y +
                    with(density) { padding.calculateTopPadding().toPx() }
            },
    ) {
        if (isThreaded) {
            items(feedThreads, key = { it.rootId }) { thread ->
                FeedThreadCard(
                    thread = thread,
                    profileFor = { pubkey -> allProfiles[pubkey] },
                    profiles = allProfiles,
                    openNoteId = expandedNoteId,
                    onOpenNoteChange = { id -> expandedNoteId = id },
                    isExpanded = threadFolds[thread.rootId] ?: false,
                    onExpandedChange = { expanded -> threadFolds[thread.rootId] = expanded },
                    onProfileClick = openProfile,
                    avatarMenu = feedAvatarMenu,
                    onTrustWeb = { author -> trustWebAuthor = author },
                    onOpenThread = { note -> onNoteClick(note.id) },
                    onFetchMissingNote = viewModel::fetchMissingNote,
                    rootUnavailable = thread.rootId in unavailableNoteIds,
                    lineAnchor = threadLineAnchor,
                    bareRepostDisplay = { note -> rememberBareRepostDisplay(note, viewModel) },
                    quotesFor = { note -> rememberCondensedQuotes(note, viewModel.quotedNotesCache, viewModel::quotedNoteFor) },
                    quoteActions = quoteActions,
                    // iOS: 12pt sides in threaded mode, 12pt between rows.
                    modifier = Modifier.padding(horizontal = 12.dp, vertical = 6.dp),
                    expandedRow = { note, _ ->
                        FeedFullNoteRow(
                            note = note,
                            viewModel = viewModel,
                            allProfiles = allProfiles,
                            onNoteClick = onNoteClick,
                            onArticleClick = onArticleClick,
                            onProfileClick = openProfile,
                            onReply = onReply ?: { _ -> onCompose() },
                            onQuote = onQuote ?: {},
                            onZap = viewModel::quickZap,
                            onLongPressZap = { id -> zapNoteId = id },
                            onNoLightningAddress = { showNoLightningAddress = true },
                            onBroadcast = { id -> broadcastNoteId = id },
                            onTrustWeb = { author -> trustWebAuthor = author },
                            onReport = { id -> reportNoteId = id },
                            onBlock = { id -> blockNoteId = id },
                            onDelete = { id -> deleteNoteId = id },
                            onLongPressLike = { id -> emojiPickerNoteId = id },
                        )
                    },
                )
            }
        } else {
        items(
            items = notes,
            key = { it.id },
            contentType = { note ->
                if (isCompact && expandedNoteId != note.id) "compact" else "full"
            }
        ) { note ->
            val isExpanded = isCompact && expandedNoteId == note.id
            val showCompact = isCompact && !isExpanded

            // Exactly the pubkeys this card can render: its author, the
            // reposter, the reply target, and anyone the text mentions.
            // Quoted notes and the parent are added below where they resolve.
            val headPubkeys = remember(note.id) {
                buildList {
                    add(note.pubkey)
                    note.repostedBy?.let(::add)
                    note.replyToPubkey?.let(::add)
                    addAll(NostrMentions.mentionedPubkeys(note.content))
                }.distinct()
            }

            // Remove expensive Crossfade animation for better scroll performance
            if (showCompact) {
                val (shownNote, repostPlaceholder) = rememberBareRepostDisplay(note, viewModel)
                // A bare repost shows its original's quotes.
                val quotes = rememberCondensedQuotes(shownNote, viewModel.quotedNotesCache, viewModel::quotedNoteFor)
                val quotedPubkeys = quotes.mapNotNull { it.note?.pubkey }
                val shownPubkeys = remember(headPubkeys, shownNote.pubkey, shownNote.content, quotedPubkeys) {
                    (headPubkeys + shownNote.pubkey + NostrMentions.mentionedPubkeys(shownNote.content) + quotedPubkeys)
                        .distinct()
                }
                // derivedStateOf, not a plain read: the computation re-runs on
                // every metadata batch, but this row only recomposes when one of
                // *its* profiles actually changed. Reading allProfiles directly
                // here would rebuild every visible card per batch instead.
                val cardProfiles by remember(shownPubkeys) {
                    derivedStateOf { shownPubkeys.resolveAgainst(allProfiles) }
                }
                // Same derivedStateOf reasoning: only this row's stats recompose it.
                val zapsOnly = LocalZapsOnlyMode.current
                val statsState = viewModel.noteStats.collectAsState()
                val engagement by remember(note.id, zapsOnly) {
                    derivedStateOf {
                        val stats = statsState.value[note.effectiveEventId]
                        CondensedEngagement(
                            reactions = if (zapsOnly) 0 else stats?.reactions ?: 0,
                            reposts = stats?.reposts ?: 0,
                        )
                    }
                }
                RankedCompactNoteCard(viewModel.popularRanks, rankId = note.id,
                    note = shownNote,
                    profile = cardProfiles[shownNote.pubkey],
                    profiles = cardProfiles,
                    repostPlaceholder = repostPlaceholder,
                    // Read once the original has resolved, which is what recomposes this row.
                    repostedOriginal = note.repostedEventId
                        ?.takeIf { note.isBareRepost && repostPlaceholder == null }
                        ?.let { viewModel.parentNotesCache.value[it] },
                    engagement = engagement,
                    onNoteClick = { id ->
                        // Expand inline first instead of navigating
                        expandedNoteId = id
                    },
                    onProfileClick = openProfile,
                    avatarMenu = feedAvatarMenu,
                    onTrustWeb = { author -> trustWebAuthor = author },
                    quotes = quotes,
                    quoteActions = quoteActions,
                    // iOS: 8pt sides for a compact row, 12pt between rows.
                    modifier = Modifier.padding(horizontal = 8.dp, vertical = 6.dp),
                )
            } else {
                FeedFullNoteRow(
                    note = note,
                    viewModel = viewModel,
                    allProfiles = allProfiles,
                    onNoteClick = onNoteClick,
                    onArticleClick = onArticleClick,
                    onProfileClick = openProfile,
                    onReply = onReply ?: { _ -> onCompose() },
                    onQuote = onQuote ?: {},
                    onZap = viewModel::quickZap,
                    onLongPressZap = { id -> zapNoteId = id },
                    onNoLightningAddress = { showNoLightningAddress = true },
                    onBroadcast = { id -> broadcastNoteId = id },
                    onTrustWeb = { author -> trustWebAuthor = author },
                    onReport = { id -> reportNoteId = id },
                    onBlock = { id -> blockNoteId = id },
                    onDelete = { id -> deleteNoteId = id },
                    onLongPressLike = { id -> emojiPickerNoteId = id },
                    // iOS: 16pt sides, 12pt between rows.
                    modifier = Modifier.padding(horizontal = 16.dp, vertical = 6.dp),
                )
            }
        }
        }

        if (isLoadingMore) {
            item {
                // iOS: a small spinner and "Loading..." in monospace.
                Row(
                    verticalAlignment = Alignment.CenterVertically,
                    horizontalArrangement = Arrangement.Center,
                    modifier = Modifier
                        .fillMaxWidth()
                        .padding(vertical = 12.dp),
                ) {
                    CircularProgressIndicator(
                        color = LocalNostrVaultColors.current.primary,
                        strokeWidth = 2.dp,
                        modifier = Modifier.size(16.dp),
                    )
                    Spacer(Modifier.width(8.dp))
                    Text(
                        text = "Loading...",
                        color = SecondaryText,
                        fontSize = 12.sp,
                        fontWeight = FontWeight.SemiBold,
                        fontFamily = FontFamily.Monospace,
                    )
                }
            }
        }
    }
}
