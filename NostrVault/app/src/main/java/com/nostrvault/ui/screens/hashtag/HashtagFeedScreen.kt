package com.nostrvault.ui.screens

import androidx.compose.foundation.background
import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.*
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.items
import androidx.compose.material3.*
import androidx.compose.runtime.*
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.alpha
import androidx.compose.ui.draw.clip
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.semantics.Role
import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.semantics.stateDescription
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.style.TextAlign
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import androidx.hilt.lifecycle.viewmodel.compose.hiltViewModel
import com.nostrvault.data.model.FeedNote
import com.nostrvault.data.model.FeedProfile
import com.nostrvault.ui.components.GlassPill
import com.nostrvault.ui.components.TrustWebDialog
import com.nostrvault.ui.components.GlassScaffold
import com.nostrvault.ui.components.NoteCard
import com.nostrvault.ui.theme.*
import kotlinx.coroutines.flow.map

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
    val loadingOlder by viewModel.loadingOlder.collectAsState()
    val notes = remember(fromFollows, fromOthers) { fromFollows + fromOthers }
    val isLoading by viewModel.isLoading.collectAsState()
    val everyone by viewModel.globalShowsEveryone.collectAsState()
    var showEveryoneWarning by remember { mutableStateOf(false) }
    val profiles by viewModel.profiles.collectAsState()
    val quotedNotesCache by viewModel.quotedNotesCache.collectAsState()
    val likedIds by viewModel.likedEventIds.collectAsState()
    val repostedIds by viewModel.repostedEventIds.collectAsState()
    val isFollowingTag by viewModel.isFollowingTag.collectAsState()
    val hasAccount by viewModel.hasAccount.collectAsState()
    val followSaving by viewModel.followSaving.collectAsState()
    val followFailed by viewModel.followFailed.collectAsState()
    val colors = LocalNostrVaultColors.current
    val tag = viewModel.tag


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
                    // The list's header carries the #tag, next to its Follow button.
                    Spacer(Modifier.weight(1f))
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
            item(key = "hashtag-header") {
                HashtagHeader(
                    tag = tag,
                    isFollowing = isFollowingTag,
                    enabled = !followSaving && hasAccount && tag.isNotEmpty(),
                    onToggle = viewModel::toggleFollow,
                )
            }
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
                LaunchedEffect(note.id) { viewModel.rowAppeared(note.id, HashtagNotesViewModel.Section.FOLLOWS) }
                HashtagNote(note, quotedNotesCache, profiles, likedIds, repostedIds, viewModel,
                    onNoteClick, onArticleClick, onProfileClick, onReply, onQuote)
            }
            if (loadingOlder == HashtagNotesViewModel.Section.FOLLOWS) {
                item(key = "hashtag-follows-older") { HashtagOlderSpinner() }
            }
            if (fromOthers.isNotEmpty() && !everyone) {
                item(key = "hashtag-others-header") { HashtagSectionHeader("More from your network") }
            }
            items(fromOthers, key = { it.id }) { note ->
                LaunchedEffect(note.id) { viewModel.rowAppeared(note.id, HashtagNotesViewModel.Section.OTHERS) }
                HashtagNote(note, quotedNotesCache, profiles, likedIds, repostedIds, viewModel,
                    onNoteClick, onArticleClick, onProfileClick, onReply, onQuote)
            }
            if (loadingOlder == HashtagNotesViewModel.Section.OTHERS) {
                item(key = "hashtag-others-older") { HashtagOlderSpinner() }
            }
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

    if (showEveryoneWarning) {
        // Under five follows it says why it's locked instead.
        com.nostrvault.ui.components.EveryoneSwitchDialog(
            onDismiss = { showEveryoneWarning = false },
            onProceed = {
                viewModel.setGlobalShowsEveryone(true)
                showEveryoneWarning = false
            },
        )
    }
}

/**
 * Big #tag with the Follow button. Followed tags are your interest list
 * (kind 10015). Styled like the profile Follow chip.
 */
@Composable
private fun HashtagHeader(tag: String, isFollowing: Boolean, enabled: Boolean, onToggle: () -> Unit) {
    val colors = LocalNostrVaultColors.current
    val content = if (isFollowing) Color.White else colors.primary
    val background = if (isFollowing) colors.primary else colors.primary.copy(alpha = 0.12f)
    Row(
        verticalAlignment = Alignment.CenterVertically,
        modifier = Modifier
            .fillMaxWidth()
            .padding(start = 16.dp, end = 16.dp, top = 4.dp, bottom = 4.dp),
    ) {
        Text(
            text = "#$tag",
            color = PrimaryText,
            fontSize = 22.sp,
            fontWeight = FontWeight.Bold,
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
                .background(background)
                .clickable(
                    enabled = enabled,
                    onClickLabel = if (isFollowing) "Unfollow #$tag" else "Follow #$tag",
                    role = Role.Button,
                    onClick = onToggle,
                )
                .padding(horizontal = 12.dp, vertical = 7.dp),
        ) {
            Icon(
                imageVector = if (isFollowing) NostrVaultIcons.Check else NostrVaultIcons.Create,
                contentDescription = null,
                tint = content,
                modifier = Modifier.size(14.dp),
            )
            Text(
                text = if (isFollowing) "Following" else "Follow",
                color = content,
                fontSize = 13.sp,
                fontWeight = FontWeight.SemiBold,
            )
        }
    }
}

@Composable
internal fun HashtagSectionHeader(title: String) {
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
internal fun HashtagNote(
    note: FeedNote,
    quotedNotesCache: Map<String, FeedNote>,
    profiles: Map<String, FeedProfile>,
    likedIds: Set<String>,
    repostedIds: Set<String>,
    viewModel: HashtagNotesViewModel,
    onNoteClick: (String) -> Unit,
    onArticleClick: (String) -> Unit,
    onProfileClick: (String) -> Unit,
    onReply: (String) -> Unit,
    onQuote: (String) -> Unit,
) {
    // Held per note: the map covers the screen, so nothing scrolls it away.
    // Whose web: the author's, or the parent's from the reply header's avatar.
    var trustWebAuthor by remember { mutableStateOf<String?>(null) }
    val quotedNotesMap = remember(note.id, note.quotedEventIds, quotedNotesCache) {
        note.quotedEventIds.mapNotNull { qid ->
            viewModel.quotedNoteFor(qid)?.let { qid to it }
        }.toMap()
    }
    NoteCard(
        note = note,
        avatarMenu = viewModel.avatarMenu,
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
        onZap = { viewModel.zapNote(note.effectiveEventId, note.effectiveAuthor) },
        onTrustWeb = if (viewModel.isOwnNote(note.effectiveAuthor)) null else ({ author: String -> trustWebAuthor = author }),
    )
    HorizontalDivider(color = SeparatorColor, thickness = 0.5.dp)
    trustWebAuthor?.let { author ->
        TrustWebDialog(
            author = author,
            initialPath = null,
            onProfileClick = onProfileClick,
            onDismiss = { trustWebAuthor = null },
        )
    }
}

/** Under a group while its next older page loads. */
@Composable
internal fun HashtagOlderSpinner() {
    Box(Modifier.fillMaxWidth().padding(vertical = 12.dp), contentAlignment = Alignment.Center) {
        CircularProgressIndicator(modifier = Modifier.size(22.dp), strokeWidth = 2.dp)
    }
}
