package com.nostrvault.ui.screens.feed

import androidx.compose.foundation.layout.*
import androidx.compose.material3.*
import androidx.compose.runtime.*
import androidx.compose.ui.Modifier
import kotlinx.coroutines.flow.first
import com.nostrvault.data.model.FeedProfile
import com.nostrvault.data.model.FeedNote
import com.nostrvault.ui.components.AvatarMenuActions
import com.nostrvault.ui.components.RepostPlaceholder
import com.nostrvault.ui.components.FeedThreadCard
import com.nostrvault.ui.components.NoteCard
import com.nostrvault.ui.components.NostrMentions
import com.nostrvault.ui.theme.*

// ── Full note row ───────────────────────────────────────────────
// The expanded-mode card, factored out so the flat feed and a tapped-open
// line inside a FeedThreadCard render the exact same row (same profile
// resolution, same callbacks) instead of drifting apart.

@Composable
internal fun FeedFullNoteRow(
    note: FeedNote,
    viewModel: FeedViewModel,
    allProfiles: Map<String, FeedProfile>,
    onNoteClick: (String) -> Unit,
    onArticleClick: (String) -> Unit,
    onProfileClick: (String) -> Unit,
    onReply: (String) -> Unit,
    onQuote: (String) -> Unit,
    onZap: (String) -> Unit,
    onLongPressZap: (String) -> Unit,
    onNoLightningAddress: () -> Unit,
    onBroadcast: (String) -> Unit,
    onTrustWeb: (String) -> Unit,
    onReport: (String) -> Unit,
    onBlock: (String) -> Unit,
    onDelete: (String) -> Unit,
    onLongPressLike: (String) -> Unit,
    modifier: Modifier = Modifier,
) {
    // A bare repost is drawn as the note it points at, once that arrives.
    val (shownNote, repostPlaceholder) = rememberBareRepostDisplay(note, viewModel)
    // The row remembers per note id; the original landing has to start it over.
    key(shownNote.pubkey, shownNote.content) {
        FeedFullNoteRowContent(
            note = shownNote,
            repostPlaceholder = repostPlaceholder,
            viewModel = viewModel,
            allProfiles = allProfiles,
            onNoteClick = onNoteClick,
            onArticleClick = onArticleClick,
            onProfileClick = onProfileClick,
            onReply = onReply,
            onQuote = onQuote,
            onZap = onZap,
            onLongPressZap = onLongPressZap,
            onNoLightningAddress = onNoLightningAddress,
            onBroadcast = onBroadcast,
            onTrustWeb = onTrustWeb,
            onReport = onReport,
            onBlock = onBlock,
            onDelete = onDelete,
            onLongPressLike = onLongPressLike,
            modifier = modifier,
        )
    }
}

/**
 * A bare repost (empty content plus an `e` tag, NIP-18) as its row shows it:
 * the original credited to the reposter once it has been fetched, and until
 * then the repost with a loading line, or an unavailable one when no relay had
 * the original. Any other note comes back as it is.
 */
@Composable
internal fun rememberBareRepostDisplay(note: FeedNote, viewModel: FeedViewModel): Pair<FeedNote, RepostPlaceholder?> {
    val refId = note.repostedEventId?.takeIf { note.isBareRepost }
    val parentsState = viewModel.parentNotesCache.collectAsState()
    val unavailableState = viewModel.unavailableNoteIds.collectAsState()
    val original by remember(note.id) {
        derivedStateOf { refId?.let { parentsState.value[it] }?.takeIf { it.kind != 6 } }
    }
    val unavailable by remember(note.id) { derivedStateOf { refId != null && refId in unavailableState.value } }
    if (refId == null) return note to null
    val shown = original?.let { note.withRepostedOriginal(it) }
        // Credited the way an embedded repost is, to the author its `p` tag names.
        ?: note.copy(
            pubkey = note.tags.firstOrNull { it.size >= 2 && it[0] == "p" }?.get(1) ?: note.pubkey,
            repostedBy = note.pubkey,
        )
    // The feed fetches profiles for the authors of the notes it receives, and
    // here that is the reposter; the row is credited to the original's author.
    LaunchedEffect(shown.pubkey) { viewModel.fetchMissingProfiles(listOf(shown.pubkey)) }
    return when {
        original != null -> shown to null
        unavailable -> shown to RepostPlaceholder.UNAVAILABLE
        else -> shown to RepostPlaceholder.LOADING
    }
}

@Composable
private fun FeedFullNoteRowContent(
    note: FeedNote,
    repostPlaceholder: RepostPlaceholder?,
    viewModel: FeedViewModel,
    allProfiles: Map<String, FeedProfile>,
    onNoteClick: (String) -> Unit,
    onArticleClick: (String) -> Unit,
    onProfileClick: (String) -> Unit,
    onReply: (String) -> Unit,
    onQuote: (String) -> Unit,
    onZap: (String) -> Unit,
    onLongPressZap: (String) -> Unit,
    onNoLightningAddress: () -> Unit,
    onBroadcast: (String) -> Unit,
    onTrustWeb: (String) -> Unit,
    onReport: (String) -> Unit,
    onBlock: (String) -> Unit,
    onDelete: (String) -> Unit,
    onLongPressLike: (String) -> Unit,
    modifier: Modifier = Modifier,
) {
    val headPubkeys = remember(note.id) {
        buildList {
            add(note.pubkey)
            note.repostedBy?.let(::add)
            note.replyToPubkey?.let(::add)
            addAll(NostrMentions.mentionedPubkeys(note.content))
        }.distinct()
    }
    // Subscribed here, not read with `viewModel.isLiked(...)`: a plain
    // StateFlow `.value` read is invisible to Compose, so the row skipped
    // recomposition and a tapped heart, a zap or a late-arriving
    // parent never showed until the row scrolled off and back. derivedStateOf
    // narrows each to this note, so another note's like does not redraw it.
    val likedState = viewModel.likedEventIds.collectAsState()
    val zappedState = viewModel.zappedEventIds.collectAsState()
    val parentsState = viewModel.parentNotesCache.collectAsState()
    val parentNextState = viewModel.parentIsNextNote.collectAsState()
    val quotedState = viewModel.quotedNotesCache.collectAsState()
    val repostedState = viewModel.repostedEventIds.collectAsState()
    // Likes and zaps are recorded against effectiveEventId (EngagementBar
    // sends it) and reactions are counted against the e-tag target, so a
    // repost is looked up by the note it reposts.
    val isLiked by remember(note.id) { derivedStateOf { note.effectiveEventId in likedState.value } }
    val isZapped by remember(note.id) { derivedStateOf { note.effectiveEventId in zappedState.value } }
    val parentEventId = note.parentEventId
    val parentNote by remember(note.id) { derivedStateOf { parentEventId?.let { parentsState.value[it] } } }
    val isParentNext by remember(note.id) {
        derivedStateOf { parentEventId != null && note.id in parentNextState.value }
    }

    val isReposted by remember(note.id) { derivedStateOf { note.effectiveEventId in repostedState.value } }
    // The read of quotedState is what subscribes; quotedNoteFor resolves against
    // the same caches. A parent landing for some other note recomputes this
    // but compares equal, so this row does not redraw.
    val quotedNotesMap by remember(note.id) {
        derivedStateOf {
            quotedState.value
            if (note.quotedEventIds.isEmpty()) {
                emptyMap()
            } else {
                note.quotedEventIds.mapNotNull { qid -> viewModel.quotedNoteFor(qid)?.let { qid to it } }.toMap()
            }
        }
    }

    val cardPubkeys = remember(headPubkeys, parentNote?.pubkey, quotedNotesMap) {
        (headPubkeys + listOfNotNull(parentNote?.pubkey) + quotedNotesMap.values.map { it.pubkey }).distinct()
    }
    val cardProfiles by remember(cardPubkeys) {
        derivedStateOf { cardPubkeys.resolveAgainst(allProfiles) }
    }
    // Zap bolt (iOS FeedView): only with a wallet; tap zaps the default
    // amount, long-press picks one; faint, and an explanation on tap, when
    // the author has no lightning address.
    val hasWallet by viewModel.hasWallet.collectAsState()
    val autoplayVideos by viewModel.autoplayVideos.collectAsState()
    val authorProfile = cardProfiles[note.pubkey]
    val hasLightning = !authorProfile?.lud16.isNullOrBlank() || !authorProfile?.lud06.isNullOrBlank()

    NoteCard(
        note = note,
        profile = cardProfiles[note.pubkey],
        profiles = cardProfiles,
        quotedNotes = quotedNotesMap,
        isLiked = isLiked,
        isZapped = isZapped,
        isReposted = isReposted,
        repostedByProfile = note.repostedBy?.let { cardProfiles[it] },
        replyToProfile = note.replyToPubkey?.let { cardProfiles[it] },
        repostPlaceholder = repostPlaceholder,
        parentNote = parentNote,
        parentIsNext = isParentNext,
        showReplyContext = true,
        onNoteClick = onNoteClick,
        onArticleClick = onArticleClick,
        onProfileClick = onProfileClick,
        onLike = viewModel::likeNote,
        onRepost = viewModel::repostNote,
        onZap = if (hasWallet) {
            { id -> if (hasLightning) onZap(id) else onNoLightningAddress() }
        } else null,
        onLongPressZap = if (hasWallet && hasLightning) onLongPressZap else null,
        zapDimmed = !hasLightning,
        onReply = onReply,
        onQuote = onQuote,
        onBroadcast = onBroadcast,
        // Your own notes have no path to show.
        onTrustWeb = if (viewModel.isOwnNote(note.effectiveAuthor)) null else onTrustWeb,
        // Every note gets an overflow menu. Gating this on your own notes
        // meant other people's notes had no menu at all, so reporting and
        // blocking were only reachable two navigations deep — from the note
        // screen, which you have to open the content to see.
        // A repost row's Delete removes the repost, so it is yours when you
        // reposted it, not when you wrote the note it carries.
        isOwnNote = viewModel.isOwnNote(note.publisher),
        onReport = { onReport(note.id) },
        onBlock = { onBlock(note.id) },
        onDelete = { onDelete(note.id) },
        onLongPressLike = onLongPressLike,
        onRetryParent = viewModel::retryMissingNote,
        autoplayVideos = autoplayVideos,
        avatarMenu = rememberFeedAvatarMenu(viewModel),
        modifier = modifier,
    )
}

/**
 * The avatar quick menu for the feed's rows, full, compact and threaded alike
 * (iOS AuthorQuickMenu on FeedNoteRow and CondensedNoteLine). While Fill your
 * feed is on, the photo opens the profile card like the name instead, rather
 * than a quick Follow that skips looking first.
 */
@Composable
internal fun rememberFeedAvatarMenu(viewModel: FeedViewModel): AvatarMenuActions? {
    val opensProfileCard = com.nostrvault.vaultguide.FillYourFeedGuide.opensProfileCard(
        com.nostrvault.vaultguide.FillYourFeedGuide.showsMeter(
            com.nostrvault.vaultguide.FillYourVaultCoordinator.phase.collectAsState().value,
            com.nostrvault.vaultguide.FillYourVaultCoordinator.meterOn.collectAsState().value,
        ),
    )
    val menu = remember(viewModel) {
        AvatarMenuActions(
            isOwn = viewModel::isOwnNote,
            isFollowed = viewModel::isFollowing,
            onFollow = viewModel::followUser,
            onUnfollow = viewModel::unfollowUser,
            onBlock = viewModel::blockUser,
        )
    }
    return if (opensProfileCard) null else menu
}
