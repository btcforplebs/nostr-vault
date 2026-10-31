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
import androidx.compose.ui.text.font.FontFamily
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.Dp
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
 * - First media, whole at its own shape (tall 220dp max, others 180dp)
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
    // Someone you follow can quote a blocked person: the card hides them,
    // words and picture, and a tap opens nothing. iOS QuotedNoteView.
    val blocked = rememberBlockedPubkeys()
    if (!com.nostrvault.data.model.BlockedPeople.showsQuote(note.pubkey, note.kind, note.tags, blocked)) {
        BlockedQuotePlaceholder(modifier)
        return
    }
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

    val meta = if (note.kind == ArticleMeta.KIND) {
        remember(note.id, note.tags) { ArticleMeta.from(note) }
    } else null

    Surface(
        shape = RoundedCornerShape(8.dp),
        color = TertiaryGroupedBg,
        // iOS QuotedNoteView: a 1pt borderStrong stroke, the only real cue
        // that the card is nested inside another (the fill step alone is a seam).
        border = BorderStroke(1.dp, BorderStrong),
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

                Spacer(Modifier.width(8.dp))

                Text(
                    text = profile?.bestName ?: "Someone",
                    color = PrimaryText.copy(alpha = 0.9f),
                    fontWeight = FontWeight.SemiBold,
                    fontSize = 12.sp,
                    maxLines = 1,
                    overflow = TextOverflow.Ellipsis,
                    modifier = Modifier.weight(1f),
                )

                Spacer(Modifier.width(6.dp))

                Text(
                    text = formatTimestamp(note.createdAt.time / 1000),
                    color = SecondaryText.copy(alpha = 0.7f),
                    fontSize = 10.sp,
                    fontFamily = FontFamily.Monospace,
                )
            }

            if (meta != null) {
                Spacer(Modifier.height(6.dp))
                QuotedArticleBody(meta)
            } else if (note.kind == com.nostrvault.data.model.SnoObject.KIND) {
                // A 3D object (SNO): its content is geometry, not text to print.
                Spacer(Modifier.height(8.dp))
                com.nostrvault.ui.components.sno.SnoQuoteBody(note)
            } else {
                // Content
                if (note.content.isNotBlank()) {
                    Spacer(Modifier.height(6.dp))
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
                    val url = note.mediaURLs.first()
                    // The photo's own width/height once it loads. Like iOS, the
                    // whole photo shows at that shape instead of being cropped.
                    var ratio by remember(url) { mutableStateOf<Float?>(null) }
                    Spacer(Modifier.height(6.dp))
                    AsyncImage(
                        model = ImageRequest.Builder(context)
                            .data(url)
                            .size(720) // a 220dp portrait at ~3x density
                            .crossfade(100)
                            .build(),
                        contentDescription = null,
                        contentScale = ContentScale.Fit,
                        onSuccess = { state ->
                            val size = state.painter.intrinsicSize
                            if (size.width > 0f && size.height > 0f) ratio = size.width / size.height
                        },
                        modifier = (ratio?.let { r ->
                            Modifier
                                .heightIn(max = quoteImageMaxHeight(r))
                                .aspectRatio(r)
                        } ?: Modifier
                            .fillMaxWidth()
                            .heightIn(max = quoteImageMaxHeight(null))
                            .background(TertiaryGroupedBg))
                            .clip(RoundedCornerShape(6.dp)),
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
/** The active account's blocked people (hex), current as you block and unblock. */
@Composable
private fun rememberBlockedPubkeys(): Set<String> {
    val context = LocalContext.current
    val feedService = remember(context) {
        dagger.hilt.android.EntryPointAccessors
            .fromApplication(context.applicationContext, LiveEmbedEntryPoint::class.java)
            .feedService()
    }
    val config by feedService.configStore.config.collectAsState()
    return remember(feedService, config) { feedService.blockedHexForActiveAccount() }
}

/** What stands in for a quote by someone you blocked. iOS QuotedNoteView.blockedPlaceholder. */
@Composable
private fun BlockedQuotePlaceholder(modifier: Modifier) {
    Text(
        "Quote from someone you blocked",
        fontSize = 12.sp,
        color = SecondaryText,
        modifier = modifier
            .fillMaxWidth()
            .clip(RoundedCornerShape(8.dp))
            .background(TertiaryGroupedBg)
            .padding(10.dp),
    )
}

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
    // An unresolved naddr is a coordinate, not an event id, so handing it to
    // the note screen opens a route that can never load. Once it resolves the
    // card replaces this and is tappable.
    val isCoordinate = QuoteRef.key(identifier) is QuoteRef.Key.Address

    Surface(
        shape = RoundedCornerShape(8.dp),
        color = TertiaryGroupedBg,
        // iOS QuotedNoteView: a 1pt borderStrong stroke, the only real cue
        // that the card is nested inside another (the fill step alone is a seam).
        border = BorderStroke(1.dp, BorderStrong),
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

/** iOS QuotedNoteView: tall photos up to 220, landscape/square/unknown up to 180. */
internal fun quoteImageMaxHeight(ratio: Float?): Dp =
    if (ratio != null && ratio < 1f) 220.dp else 180.dp
