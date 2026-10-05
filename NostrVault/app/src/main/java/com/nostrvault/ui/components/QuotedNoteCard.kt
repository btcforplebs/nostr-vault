package com.nostrvault.ui.components

import androidx.compose.foundation.BorderStroke
import androidx.compose.foundation.background
import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.*
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material3.*
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
import coil.compose.AsyncImage
import coil.request.ImageRequest
import com.nostrvault.data.model.ArticleMeta
import com.nostrvault.data.model.FeedNote
import com.nostrvault.data.model.FeedProfile
import com.nostrvault.data.model.MarketListing
import com.nostrvault.data.model.QuoteRef
import com.nostrvault.ui.theme.*
import kotlinx.coroutines.delay

/**
 * Embedded quoted note card, rendered below note content when a note
 * references another via `nostr:note1...` or `nostr:nevent1...`.
 *
 * Matches the iOS QuotedNoteView layout:
 * - 18dp avatar + author name (12sp bold) + timestamp (10sp)
 * - Content (13sp, secondary, 3-line max)
 * - First media thumbnail (if present, 180dp max height)
 * - TertiaryGroupedBg background, themed border, 8dp corner radius
 *
 * A quoted long-form post gets a different body: its content is a whole
 * Markdown document, so three lines of it shows `##` markup rather than the
 * article. The headline, cover and summary live in tags instead.
 */
@Composable
fun QuotedNoteCard(
    note: FeedNote,
    profile: FeedProfile?,
    profiles: Map<String, FeedProfile> = emptyMap(),
    onClick: (String) -> Unit,
    /**
     * Where a quoted article opens. Null falls back to [onClick], which lands
     * on the note screen — that renders kind-1 threads and would show the
     * Markdown source, so a screen with a reader should pass this.
     */
    onArticleClick: ((String) -> Unit)? = null,
    modifier: Modifier = Modifier,
) {
    // A shared listing's content is usually NIP-15 JSON, which the note body
    // below would print. Same as the iPhone (#237): a listing card instead.
    val listing = if (note.kind in MarketListing.KINDS) {
        remember(note.id) {
            MarketListing.parse(note.id, note.pubkey, note.kind, note.content, note.createdAt.time / 1000, note.tags)
        }
    } else null
    if (listing != null) {
        com.nostrvault.ui.screens.feed.QuotedListingCard(listing, profile, modifier)
        return
    }
    // A quoted live stream is something to watch, not text to read: the
    // Live-tab tile, and a tap plays it rather than opening a thread (a stream
    // event has none). iOS #172.
    val stream = remember(note.id) { com.nostrvault.data.model.LiveStream.from(note) }
    if (stream != null) {
        LiveStreamEmbed(stream, modifier)
        return
    }

    val colors = LocalNostrVaultColors.current
    val meta = if (note.kind == ArticleMeta.KIND) {
        remember(note.id, note.tags) { ArticleMeta.from(note) }
    } else null

    Surface(
        shape = RoundedCornerShape(8.dp),
        color = TertiaryGroupedBg,
        border = BorderStroke(
            // Embedded in a note, so it tracks NoteCard's OLED bump
            // rather than sitting fainter than the card it lives inside.
            if (LocalOledMode.current) 0.8.dp else 0.5.dp,
            colors.primary.copy(alpha = if (LocalOledMode.current) 0.18f else 0.12f),
        ),
        modifier = modifier
            .fillMaxWidth()
            .clickable {
                if (meta != null && onArticleClick != null) onArticleClick(note.id) else onClick(note.id)
            },
    ) {
        Column(
            modifier = Modifier.padding(10.dp),
        ) {
            // Author header
            Row(
                verticalAlignment = Alignment.CenterVertically,
            ) {
                AvatarImage(
                    url = profile?.pictureURL,
                    pubkey = note.pubkey,
                    size = 18.dp,
                    displayName = profile?.bestName,
                )

                Spacer(Modifier.width(6.dp))

                Text(
                    text = profile?.bestName ?: note.pubkey.take(8) + "...",
                    color = PrimaryText,
                    fontWeight = FontWeight.SemiBold,
                    fontSize = 12.sp,
                    maxLines = 1,
                    overflow = TextOverflow.Ellipsis,
                    modifier = Modifier.weight(1f),
                )

                Spacer(Modifier.width(6.dp))

                Text(
                    text = formatTimestamp(note.createdAt.time / 1000),
                    color = TertiaryText,
                    fontSize = 10.sp,
                )
            }

            if (meta != null) {
                Spacer(Modifier.height(6.dp))
                QuotedArticleBody(meta)
            } else {
                // Content
                if (note.content.isNotBlank()) {
                    Spacer(Modifier.height(4.dp))
                    Text(
                        text = remember(note.content, profiles, note.mediaURLs) {
                            NostrMentions.toPlainText(note.content, profiles, note.mediaURLs.toSet())
                        },
                        color = SecondaryText,
                        fontSize = 13.sp,
                        lineHeight = 17.sp,
                        maxLines = 3,
                        overflow = TextOverflow.Ellipsis,
                    )
                }

                // First media thumbnail
                if (note.mediaURLs.isNotEmpty()) {
                    val context = LocalContext.current
                    Spacer(Modifier.height(6.dp))
                    AsyncImage(
                        model = ImageRequest.Builder(context)
                            .data(note.mediaURLs.first())
                            .size(360) // Max 180dp at 2x density
                            .crossfade(100)
                            .build(),
                        contentDescription = null,
                        contentScale = ContentScale.Crop,
                        modifier = Modifier
                            .fillMaxWidth()
                            .heightIn(max = 180.dp)
                            .clip(RoundedCornerShape(6.dp))
                            .background(TertiaryGroupedBg),
                    )
                }
            }
        }
    }
}

/**
 * The body of a quoted long-form post: cover thumbnail, an "Article" label so
 * it is not mistaken for a note, headline and summary. Read entirely from
 * [ArticleMeta], so a 20,000-word body is never laid out to draw a card.
 */
@Composable
private fun QuotedArticleBody(meta: ArticleMeta) {
    val colors = LocalNostrVaultColors.current
    val context = LocalContext.current

    Row(verticalAlignment = Alignment.Top) {
        meta.imageUrl?.let { imageUrl ->
            AsyncImage(
                model = ImageRequest.Builder(context)
                    .data(imageUrl)
                    .size(112)
                    .crossfade(100)
                    .build(),
                contentDescription = null,
                contentScale = ContentScale.Crop,
                modifier = Modifier
                    .size(56.dp)
                    .clip(RoundedCornerShape(6.dp))
                    .background(TertiaryGroupedBg),
            )
            Spacer(Modifier.width(10.dp))
        }

        Column(modifier = Modifier.weight(1f)) {
            Text(
                text = "Article",
                color = colors.primary.copy(alpha = 0.8f),
                fontWeight = FontWeight.SemiBold,
                fontSize = 10.sp,
            )
            Spacer(Modifier.height(3.dp))
            Text(
                text = meta.title,
                color = PrimaryText,
                fontWeight = FontWeight.SemiBold,
                fontSize = 13.sp,
                lineHeight = 17.sp,
                maxLines = 2,
                overflow = TextOverflow.Ellipsis,
            )
            meta.summary?.let { summary ->
                Spacer(Modifier.height(3.dp))
                Text(
                    text = summary,
                    color = SecondaryText,
                    fontSize = 12.sp,
                    lineHeight = 16.sp,
                    maxLines = 2,
                    overflow = TextOverflow.Ellipsis,
                )
            }
        }
    }
}

/** How long a parent or quote skeleton waits before saying it could not load (iOS: 12 s). */
internal const val PLACEHOLDER_TIMEOUT_MS = 12_000L

/**
 * True once [PLACEHOLDER_TIMEOUT_MS] has passed for [key] without the caller
 * replacing the placeholder. A new [attempt] (Retry) starts the clock again.
 */
@Composable
internal fun rememberPlaceholderTimedOut(key: Any, attempt: Int = 0): Boolean {
    var timedOut by remember(key, attempt) { mutableStateOf(false) }
    LaunchedEffect(key, attempt) {
        delay(PLACEHOLDER_TIMEOUT_MS)
        timedOut = true
    }
    return timedOut
}

/**
 * Placeholder for a quoted note that hasn't been fetched yet. After
 * [PLACEHOLDER_TIMEOUT_MS] it says "Quoted note unavailable" instead of
 * skeleton-loading forever (iOS FeedView quoteFetchFailed). The real card
 * still replaces it if the note turns up later.
 */
@Composable
fun QuotedNotePlaceholder(
    identifier: String,
    onClick: (String) -> Unit,
    modifier: Modifier = Modifier,
) {
    if (rememberPlaceholderTimedOut(identifier)) {
        Text(
            text = "Quoted note unavailable",
            color = SecondaryText,
            fontSize = 12.sp,
            modifier = modifier.fillMaxWidth(),
        )
        return
    }
    val colors = LocalNostrVaultColors.current
    // An unresolved naddr is a coordinate, not an event id, so handing it to
    // the note screen opens a route that can never load. Once it resolves the
    // card replaces this and is tappable.
    val isCoordinate = QuoteRef.key(identifier) is QuoteRef.Key.Address

    Surface(
        shape = RoundedCornerShape(8.dp),
        color = TertiaryGroupedBg,
        border = BorderStroke(
            // Embedded in a note, so it tracks NoteCard's OLED bump
            // rather than sitting fainter than the card it lives inside.
            if (LocalOledMode.current) 0.8.dp else 0.5.dp,
            colors.primary.copy(alpha = if (LocalOledMode.current) 0.18f else 0.12f),
        ),
        modifier = modifier
            .fillMaxWidth()
            .then(if (isCoordinate) Modifier else Modifier.clickable { onClick(identifier) }),
    ) {
        // Laid out like [QuotedNoteCard]: header row, then two lines of
        // body in its text style, so the card does not grow when the note
        // arrives (iOS `QuotedNoteSkeleton`).
        Column(modifier = Modifier.padding(10.dp)) {
            Row(verticalAlignment = Alignment.CenterVertically) {
                Box(
                    modifier = Modifier
                        .size(18.dp)
                        .clip(CircleShape)
                        .background(SecondaryGroupedBg),
                )
                Spacer(Modifier.width(6.dp))
                Text(
                    text = if (isCoordinate) "Loading article..." else "Loading quoted note...",
                    color = TertiaryText,
                    fontWeight = FontWeight.SemiBold,
                    fontSize = 12.sp,
                    maxLines = 1,
                    overflow = TextOverflow.Ellipsis,
                    modifier = Modifier.weight(1f),
                )
            }
            Spacer(Modifier.height(4.dp))
            SkeletonTextLine(fontSize = 13.sp, lineHeight = 17.sp, widthFraction = 0.9f, color = SecondaryGroupedBg)
            SkeletonTextLine(fontSize = 13.sp, lineHeight = 17.sp, widthFraction = 0.55f, color = SecondaryGroupedBg)
        }
    }
}
