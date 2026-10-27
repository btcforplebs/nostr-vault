package com.nostrvault.ui.components

import androidx.compose.foundation.BorderStroke
import androidx.compose.foundation.background
import androidx.compose.foundation.border
import androidx.compose.foundation.ExperimentalFoundationApi
import androidx.compose.foundation.clickable
import androidx.compose.foundation.combinedClickable
import androidx.compose.foundation.layout.*
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material3.AlertDialog
import androidx.compose.material3.Icon
import androidx.compose.material3.TextButton
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.layout.ContentScale
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.text.font.FontFamily
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import coil.compose.AsyncImage
import coil.request.ImageRequest
import com.nostrvault.data.model.FeedNote
import com.nostrvault.data.model.FeedProfile
import com.nostrvault.data.model.ReactionDetail
import com.nostrvault.data.model.RepostDetail
import com.nostrvault.ui.theme.*
import java.util.Date

/**
 * Vault-style note card matching iOS VaultNoteRow exactly.
 * Two modes: compact (no engagement) and expanded (inline engagement bar).
 * No parent notes, no quick-action buttons.
 */
@OptIn(ExperimentalFoundationApi::class)
@Composable
fun VaultNoteCard(
    note: FeedNote,
    profile: FeedProfile?,
    profiles: Map<String, FeedProfile> = emptyMap(),
    /** Quoted events keyed by the lookup key `note.quotedEventIds` holds. */
    quotedNotes: Map<String, FeedNote> = emptyMap(),
    reactors: List<Pair<String, String>> = emptyList(),
    latestReactionDate: Date? = null,
    reposterPubkeys: List<String> = emptyList(),
    quoterPubkeys: List<String> = emptyList(),
    zappers: List<Pair<String, Long>> = emptyList(),
    noteType: VaultNoteType = VaultNoteType.TAGGED,
    layoutMode: VaultNoteLayoutMode = VaultNoteLayoutMode.EXPANDED,
    onNoteClick: (String) -> Unit,
    /** Where a quoted long-form post opens; the note screen shows Markdown source. */
    onArticleClick: ((String) -> Unit)? = null,
    onProfileClick: (String) -> Unit,
    /** Null opens the card's own Reactions / Reposts / Quoted By sheet (iOS NoteRow owns these). */
    onReactorsClick: (() -> Unit)? = null,
    onRepostersClick: (() -> Unit)? = null,
    onQuotersClick: (() -> Unit)? = null,
    /**
     * Long-press menu on someone else's note (iOS NoteRow's context menu).
     * Report sends a NIP-56 report with the picked reason; the caller also
     * blocks the author, as everywhere else in the app.
     */
    onReport: ((reason: String, description: String) -> Unit)? = null,
    onBlock: (() -> Unit)? = null,
    modifier: Modifier = Modifier,
) {
    val isCompact = layoutMode == VaultNoteLayoutMode.COMPACT
    var showReactors by remember { mutableStateOf(false) }
    var showReposters by remember { mutableStateOf(false) }
    var showQuoters by remember { mutableStateOf(false) }
    var showMenu by remember { mutableStateOf(false) }
    var showReport by remember { mutableStateOf(false) }
    var showBlockConfirm by remember { mutableStateOf(false) }
    val menuActions = buildList {
        if (noteType != VaultNoteType.MINE) {
            if (onReport != null) {
                add(NoteAction(NostrVaultIcons.Alert, "Report Post", destructive = true) { showReport = true })
            }
            if (onBlock != null) {
                add(NoteAction(NostrVaultIcons.Blocked, "Block User", destructive = true) { showBlockConfirm = true })
            }
        }
    }
    val colors = LocalNostrVaultColors.current
    // Zaps Only mode strips reactions from the inline engagement bar entirely.
    val effectiveReactors = if (LocalZapsOnlyMode.current) emptyList() else reactors

    // Relay-tab cards had no border at all — only a background — while feed
    // cards carried the accent outline, so posts looked different depending on
    // which tab you were on. Matches NoteCard's treatment, including its OLED
    // bump (the outline has to work harder against true black).
    val isOled = LocalOledMode.current
    val cardShape = RoundedCornerShape(if (isCompact) 10.dp else 12.dp)
    Box(
        modifier = modifier
            .fillMaxWidth()
            .clip(cardShape)
            .background(SecondaryGroupedBg)
            .border(
                BorderStroke(
                    if (isOled) 1.dp else 0.8.dp,
                    colors.primary.copy(alpha = if (isOled) 0.18f else 0.12f),
                ),
                cardShape,
            )
            .combinedClickable(
                onClick = { onNoteClick(note.id) },
                onLongClick = if (menuActions.isNotEmpty()) ({ showMenu = true }) else null,
            ),
    ) {
        NoteActionsMenu(
            expanded = showMenu,
            actions = menuActions,
            onDismiss = { showMenu = false },
        )
        if (isCompact) {
            CompactLayout(
                note = note,
                profile = profile,
                profiles = profiles,
                noteType = noteType,
                onProfileClick = onProfileClick,
            )
        } else {
            ExpandedLayout(
                note = note,
                quotedNotes = quotedNotes,
                profile = profile,
                profiles = profiles,
                onArticleClick = onArticleClick,
                onNoteClick = onNoteClick,
                reactors = effectiveReactors,
                latestReactionDate = latestReactionDate,
                reposterPubkeys = reposterPubkeys,
                quoterPubkeys = quoterPubkeys,
                zappers = zappers,
                noteType = noteType,
                onProfileClick = onProfileClick,
                onReactorsClick = onReactorsClick ?: { showReactors = true },
                onRepostersClick = onRepostersClick ?: { showReposters = true },
                onQuotersClick = onQuotersClick ?: { showQuoters = true },
            )
        }
    }

    // The engagement bar's counts open who reacted / reposted / quoted, as on
    // iOS (VaultNoteRow's ReactorsListView, RepostersListView, QuotersListView).
    // Tapping a person closes the sheet and opens their profile.
    if (showReactors) {
        ReactorsSheet(
            reactions = effectiveReactors.distinctBy { it.first }
                .map { (pubkey, emoji) -> ReactionDetail(id = pubkey, pubkey = pubkey, emoji = emoji) },
            profiles = profiles,
            onProfileClick = { showReactors = false; onProfileClick(it) },
            onDismiss = { showReactors = false },
        )
    }
    if (showReposters) {
        RepostersSheet(
            reposts = reposterPubkeys.distinct().map { RepostDetail(id = it, pubkey = it) },
            profiles = profiles,
            onProfileClick = { showReposters = false; onProfileClick(it) },
            onDismiss = { showReposters = false },
        )
    }
    if (showQuoters) {
        RepostersSheet(
            reposts = quoterPubkeys.distinct().map { RepostDetail(id = it, pubkey = it) },
            profiles = profiles,
            onProfileClick = { showQuoters = false; onProfileClick(it) },
            onDismiss = { showQuoters = false },
            title = "Quoted By",
            emptyText = "No quotes yet",
        )
    }

    if (showReport && onReport != null) {
        UGCReportDialog(
            onReport = { reason, description ->
                showReport = false
                onReport(reason, description)
            },
            onDismiss = { showReport = false },
        )
    }
    if (showBlockConfirm && onBlock != null) {
        AlertDialog(
            onDismissRequest = { showBlockConfirm = false },
            title = { Text("Block User") },
            text = { Text("Block this user? Their posts will be hidden from your feed.") },
            confirmButton = {
                TextButton(onClick = {
                    showBlockConfirm = false
                    onBlock()
                }) { Text("Block", color = ErrorRed) }
            },
            dismissButton = {
                TextButton(onClick = { showBlockConfirm = false }) { Text("Cancel") }
            },
        )
    }
}

// ── Compact Layout ─────────────────────────────────────────────
// iOS lines 128-227: 32pt avatar, name · badge · time, 2-line text, 60x60 thumbnail.

@Composable
private fun CompactLayout(
    note: FeedNote,
    profile: FeedProfile?,
    profiles: Map<String, FeedProfile>,
    noteType: VaultNoteType,
    onProfileClick: (String) -> Unit,
) {
    val context = LocalContext.current
    val firstMedia = note.mediaURLs.firstOrNull { !isAudioUrl(it) }
    // Headed by the reposter, with the original's text below, as on iOS.
    val headPubkey = note.repostedBy ?: note.pubkey
    val headProfile = if (note.repostedBy != null) profiles[headPubkey] else profile
    val displayName = headProfile?.bestName ?: "${headPubkey.take(8)}...${headPubkey.takeLast(4)}"

    Row(
        verticalAlignment = Alignment.Top,
        modifier = Modifier
            .fillMaxWidth()
            .padding(horizontal = 12.dp, vertical = 8.dp),
    ) {
        // 32dp avatar (iOS line 146)
        AvatarImage(
            url = headProfile?.pictureURL,
            pubkey = headPubkey,
            size = 32.dp,
            displayName = headProfile?.bestName,
            modifier = Modifier.clickable { onProfileClick(headPubkey) },
        )

        Spacer(Modifier.width(8.dp))

        Column(modifier = Modifier.weight(1f)) {
            // Header row: name, badge, · time, repost/reply indicators (iOS lines 153-180)
            Row(verticalAlignment = Alignment.CenterVertically) {
                Text(
                    text = displayName,
                    color = PrimaryText,
                    fontWeight = FontWeight.SemiBold,
                    fontSize = 13.sp,
                    maxLines = 1,
                    overflow = TextOverflow.Ellipsis,
                    modifier = Modifier.weight(1f, fill = false),
                )

                if (note.isFromNostrVault) {
                    Spacer(Modifier.width(4.dp))
                    NostrVaultBadge(size = 10.dp)
                }

                Spacer(Modifier.width(4.dp))

                Icon(
                    imageVector = noteType.icon,
                    contentDescription = null,
                    tint = noteType.color,
                    modifier = Modifier.size(9.dp),
                )

                Text(
                    text = " · ${formatTimestamp(note.createdAt.time / 1000)}",
                    color = SecondaryText,
                    fontSize = 11.sp,
                    fontFamily = FontFamily.Monospace,
                    maxLines = 1,
                )

                Spacer(Modifier.width(4.dp))

                // iOS line 170-174: repost indicator
                if (note.repostedBy != null) {
                    Icon(
                        imageVector = NostrVaultIcons.Repost,
                        contentDescription = null,
                        tint = RepostGreen.copy(alpha = 0.7f),
                        modifier = Modifier.size(10.dp),
                    )
                }
                // iOS line 175-179: reply indicator
                if (note.isReply) {
                    Icon(
                        imageVector = NostrVaultIcons.Reply,
                        contentDescription = null,
                        tint = LocalNostrVaultColors.current.primary.copy(alpha = 0.7f),
                        modifier = Modifier.size(10.dp),
                    )
                }
            }

            // 2-line plain text (iOS lines 182-188)
            if (note.content.isNotBlank()) {
                Spacer(Modifier.height(2.dp))
                Text(
                    text = remember(note.content, profiles, note.mediaURLs) {
                        NostrMentions.toPlainText(note.content, profiles, note.mediaURLs.toSet()).replace("\n", " ")
                    },
                    color = PrimaryText,
                    fontSize = 14.sp,
                    lineHeight = 18.sp,
                    maxLines = 2,
                    overflow = TextOverflow.Ellipsis,
                )
            }
        }

        // 60x60 thumbnail (iOS lines 193-211)
        if (firstMedia != null) {
            Spacer(Modifier.width(8.dp))
            Box(
                contentAlignment = Alignment.Center,
                modifier = Modifier
                    .size(60.dp)
                    .clip(RoundedCornerShape(6.dp))
                    .background(TertiaryGroupedBg),
            ) {
                AsyncImage(
                    model = ImageRequest.Builder(context)
                        .data(firstMedia)
                        .size(180)
                        .crossfade(100)
                        .build(),
                    contentDescription = null,
                    contentScale = ContentScale.Crop,
                    modifier = Modifier.fillMaxSize(),
                )
                if (note.mediaURLs.size > 1) {
                    Box(
                        contentAlignment = Alignment.Center,
                        modifier = Modifier
                            .align(Alignment.BottomEnd)
                            .padding(4.dp)
                            .background(Color.Black.copy(alpha = 0.7f), RoundedCornerShape(12.dp))
                            .padding(horizontal = 6.dp, vertical = 3.dp),
                    ) {
                        Text(
                            text = "+${note.mediaURLs.size - 1}",
                            color = Color.White,
                            fontSize = 10.sp,
                            fontWeight = FontWeight.Bold,
                        )
                    }
                }
            }
        }
    }
}

// ── Expanded Layout ────────────────────────────────────────────
// iOS lines 229-364: 40pt avatar, header row, content, media, engagement bar.

@Composable
private fun ExpandedLayout(
    note: FeedNote,
    profile: FeedProfile?,
    profiles: Map<String, FeedProfile>,
    quotedNotes: Map<String, FeedNote>,
    onArticleClick: ((String) -> Unit)?,
    reactors: List<Pair<String, String>>,
    latestReactionDate: Date?,
    reposterPubkeys: List<String>,
    quoterPubkeys: List<String>,
    zappers: List<Pair<String, Long>>,
    noteType: VaultNoteType,
    onNoteClick: (String) -> Unit,
    onProfileClick: (String) -> Unit,
    onReactorsClick: (() -> Unit)?,
    onRepostersClick: (() -> Unit)?,
    onQuotersClick: (() -> Unit)?,
) {
    // A repost is headed by whoever reposted it, with the original note in a
    // card below, as on iOS (NoteRow + RepostedNoteView). [FeedNote] unpacks a
    // repost to the original author, so the header reads [FeedNote.repostedBy].
    val reposter = note.repostedBy
    val headPubkey = reposter ?: note.pubkey
    val headProfile = if (reposter != null) profiles[reposter] else profile
    val displayName = headProfile?.bestName ?: "${headPubkey.take(8)}...${headPubkey.takeLast(4)}"

    // iOS: VStack(alignment: .leading, spacing: 10).padding(14)
    Column(
        modifier = Modifier
            .fillMaxWidth()
            .padding(14.dp),
        verticalArrangement = Arrangement.spacedBy(10.dp),
    ) {
        // Header: avatar + info row (iOS lines 239-284)
        Row(
            verticalAlignment = Alignment.CenterVertically,
            horizontalArrangement = Arrangement.spacedBy(12.dp),
        ) {
            // 40dp avatar (iOS line 240-244)
            AvatarImage(
                url = headProfile?.pictureURL,
                pubkey = headPubkey,
                size = 40.dp,
                displayName = headProfile?.bestName,
                modifier = Modifier.clickable { onProfileClick(headPubkey) },
            )

            // iOS: VStack > HStack(spacing: 6) { name, badges, noteType, Spacer, time }
            Row(
                verticalAlignment = Alignment.CenterVertically,
                modifier = Modifier.weight(1f),
            ) {
                // Leading group (name + badges + note type) fills the row so the
                // timestamp pins flush-right. A single weighted child here avoids
                // the two-weight tug-of-war that left the time floating mid-row.
                Row(
                    verticalAlignment = Alignment.CenterVertically,
                    modifier = Modifier.weight(1f),
                ) {
                    // Name (iOS line 249-251)
                    Text(
                        text = displayName,
                        color = PrimaryText,
                        fontWeight = FontWeight.SemiBold,
                        fontSize = 14.sp,
                        maxLines = 1,
                        overflow = TextOverflow.Ellipsis,
                        modifier = Modifier.weight(1f, fill = false),
                    )

                    if (reposter == null && note.isFromNostrVault) {
                        Spacer(Modifier.width(6.dp))
                        NostrVaultBadge(size = 12.dp)
                    }

                    Spacer(Modifier.width(6.dp))

                    // Reposted badge (iOS lines 253-261)
                    if (note.repostedBy != null) {
                        Row(
                            verticalAlignment = Alignment.CenterVertically,
                            horizontalArrangement = Arrangement.spacedBy(3.dp),
                        ) {
                            Icon(
                                imageVector = NostrVaultIcons.Repost,
                                contentDescription = null,
                                tint = RepostGreen,
                                modifier = Modifier.size(10.dp),
                            )
                            Text(
                                text = "Reposted",
                                color = RepostGreen,
                                fontSize = 11.sp,
                                fontWeight = FontWeight.Medium,
                            )
                        }
                        Spacer(Modifier.width(6.dp))
                    }

                    // Reply badge (iOS lines 263-271)
                    if (note.isReply) {
                        Row(
                            verticalAlignment = Alignment.CenterVertically,
                            horizontalArrangement = Arrangement.spacedBy(3.dp),
                        ) {
                            Icon(
                                imageVector = NostrVaultIcons.Reply,
                                contentDescription = null,
                                tint = LocalNostrVaultColors.current.primary.copy(alpha = 0.7f),
                                modifier = Modifier.size(10.dp),
                            )
                            Text(
                                text = "Reply",
                                color = LocalNostrVaultColors.current.primary.copy(alpha = 0.7f),
                                fontSize = 11.sp,
                                fontWeight = FontWeight.Medium,
                            )
                        }
                        Spacer(Modifier.width(6.dp))
                    }

                    // Note type icon (iOS lines 273-275)
                    Icon(
                        imageVector = noteType.icon,
                        contentDescription = null,
                        tint = noteType.color,
                        modifier = Modifier.size(10.dp),
                    )
                }

                Spacer(Modifier.width(6.dp))

                // Timestamp (iOS lines 279-282)
                Text(
                    text = formatTimestamp(note.createdAt.time / 1000),
                    color = SecondaryText,
                    fontSize = 11.sp,
                    fontFamily = FontFamily.Monospace,
                    letterSpacing = 0.2.sp,
                )
            }
        }

        if (reposter != null) {
            RepostedNoteBlock(
                note = note,
                profile = profiles[note.pubkey],
                profiles = profiles,
                quotedNotes = quotedNotes,
                onArticleClick = onArticleClick,
                onNoteClick = onNoteClick,
                onProfileClick = onProfileClick,
            )
        } else {
            NoteBody(note, profiles, quotedNotes, onArticleClick, onNoteClick, onProfileClick)
        }

        // Engagement bar (iOS lines 338-345)
        InlineEngagementBar(
            reactors = reactors,
            latestReactionDate = latestReactionDate,
            reposterPubkeys = reposterPubkeys,
            quoterPubkeys = quoterPubkeys,
            zappers = zappers,
            profiles = profiles,
            onReactorsClick = onReactorsClick,
            onRepostersClick = onRepostersClick,
            onQuotersClick = onQuotersClick,
        )
    }
}

/** Text, media, link cards and quoted notes of a note (iOS NoteRow body). */
@Composable
private fun NoteBody(
    note: FeedNote,
    profiles: Map<String, FeedProfile>,
    quotedNotes: Map<String, FeedNote>,
    onArticleClick: ((String) -> Unit)?,
    onNoteClick: (String) -> Unit,
    onProfileClick: (String) -> Unit,
) {
    // Content text (iOS lines 296-311)
    if (note.content.isNotBlank()) {
        // Each link's card sits where the link was written (iOS #1248).
        NoteTextWithLinkCards(
            content = note.content,
            cards = note.cardLinkURLs,
            emojis = note.customEmojis,
            profiles = profiles,
            mediaURLs = note.mediaURLs.toSet(),
            onProfileClick = onProfileClick,
            onPlainTextClick = { onNoteClick(note.id) },
            lineHeight = 20.sp,
        )
    }

    // Media previews (iOS lines 314-330)
    if (note.mediaURLs.isNotEmpty()) {
        MediaPreviewRow(urls = note.mediaURLs, tags = note.tags, author = note.pubkey)
    }

    // Quoted events. This card already knew a quote existed — it suppressed
    // a link preview on exactly that condition — and then drew
    // nothing for it, so on the relay tab a quote was silently dropped.
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
    }
}

/**
 * The note a repost points at, in its own card under the reposter's header:
 * the original author, when they posted it, and its body. iOS RepostedNoteView.
 * A bare repost whose original isn't loaded says so; tapping opens it.
 */
@Composable
private fun RepostedNoteBlock(
    note: FeedNote,
    profile: FeedProfile?,
    profiles: Map<String, FeedProfile>,
    quotedNotes: Map<String, FeedNote>,
    onArticleClick: ((String) -> Unit)?,
    onNoteClick: (String) -> Unit,
    onProfileClick: (String) -> Unit,
) {
    val name = profile?.bestName ?: "${note.pubkey.take(8)}...${note.pubkey.takeLast(4)}"
    val shape = RoundedCornerShape(8.dp)
    Column(
        verticalArrangement = Arrangement.spacedBy(8.dp),
        modifier = Modifier
            .fillMaxWidth()
            .clip(shape)
            .background(TertiaryGroupedBg)
            .border(BorderStroke(0.5.dp, Color(0xFF33333F)), shape)
            .padding(10.dp),
    ) {
        Row(
            verticalAlignment = Alignment.CenterVertically,
            horizontalArrangement = Arrangement.spacedBy(8.dp),
        ) {
            AvatarImage(
                url = profile?.pictureURL,
                pubkey = note.pubkey,
                size = 28.dp,
                displayName = profile?.bestName,
                modifier = Modifier.clickable { onProfileClick(note.pubkey) },
            )
            Text(
                text = name,
                color = PrimaryText,
                fontWeight = FontWeight.SemiBold,
                fontSize = 13.sp,
                maxLines = 1,
                overflow = TextOverflow.Ellipsis,
                modifier = Modifier.weight(1f, fill = false),
            )
            if (note.isFromNostrVault) NostrVaultBadge(size = 10.dp)
            Spacer(Modifier.weight(1f))
            note.originalCreatedAtSecs?.let {
                Text(
                    text = formatTimestamp(it),
                    color = SecondaryText,
                    fontSize = 10.sp,
                    fontFamily = FontFamily.Monospace,
                )
            }
        }
        if (note.content.isBlank() && note.mediaURLs.isEmpty()) {
            Text(
                text = "Tap to open the reposted note",
                color = SecondaryText,
                fontSize = 13.sp,
            )
        } else {
            NoteBody(note, profiles, quotedNotes, onArticleClick, onNoteClick, onProfileClick)
        }
    }
}

// ── Types ──────────────────────────────────────────────────────

enum class VaultNoteType(
    val label: String,
    val icon: androidx.compose.ui.graphics.vector.ImageVector,
    val color: Color,
) {
    MINE("My Note", NostrVaultIcons.Edit, Color(0xFF9B7EDE)),
    WHITELISTED("Whitelisted", NostrVaultIcons.Verified, Color(0xFF33CC99)),
    TAGGED("Tagged", NostrVaultIcons.TagIcon, Color(0xFF5E9FFF)),
}

enum class VaultNoteLayoutMode {
    COMPACT,
    EXPANDED,
}
