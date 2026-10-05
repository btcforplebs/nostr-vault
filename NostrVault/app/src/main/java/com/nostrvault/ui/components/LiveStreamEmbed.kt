package com.nostrvault.ui.components

import androidx.activity.compose.BackHandler
import androidx.compose.foundation.BorderStroke
import androidx.compose.foundation.background
import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.*
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.filled.People
import androidx.compose.material3.Icon
import androidx.compose.material3.Surface
import androidx.compose.material3.Text
import androidx.compose.runtime.*
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.alpha
import androidx.compose.ui.draw.clip
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.semantics.Role
import androidx.compose.ui.semantics.contentDescription
import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import com.nostrvault.data.model.FeedNote
import com.nostrvault.data.model.LiveStream
import com.nostrvault.data.model.QuoteRef
import com.nostrvault.relay.HavenQuoteDecoder
import com.nostrvault.service.FeedService
import com.nostrvault.service.NostrService
import com.nostrvault.ui.screens.LiveStreamScreen
import com.nostrvault.ui.theme.*
import dagger.hilt.EntryPoint
import dagger.hilt.InstallIn
import dagger.hilt.android.EntryPointAccessors
import dagger.hilt.components.SingletonComponent
import kotlinx.coroutines.delay
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.asStateFlow

/**
 * The live player, opened from anywhere: the Live tab, or a stream embedded in
 * a note on any screen. [LiveStreamHost] draws it over the whole app, so the
 * stream object the tile showed is the one that plays (see [LiveStreamScreen]).
 */
object LiveStreamRouter {
    private val _playing = MutableStateFlow<LiveStream?>(null)
    val playing = _playing.asStateFlow()

    fun open(stream: LiveStream) { _playing.value = stream }

    fun close() { _playing.value = null }
}

@EntryPoint
@InstallIn(SingletonComponent::class)
interface LiveEmbedEntryPoint {
    fun feedService(): FeedService
    fun nostrService(): NostrService
}

@Composable
private fun liveEmbedServices(): LiveEmbedEntryPoint {
    val context = LocalContext.current
    return remember(context) {
        EntryPointAccessors.fromApplication(context.applicationContext, LiveEmbedEntryPoint::class.java)
    }
}

/** The player over the whole app while [LiveStreamRouter] has a stream. */
@Composable
fun LiveStreamHost() {
    val stream by LiveStreamRouter.playing.collectAsState()
    val current = stream ?: return
    val profiles by liveEmbedServices().nostrService().profiles.collectAsState()
    BackHandler { LiveStreamRouter.close() }
    // Keyed on the stream, so opening another one starts a fresh player.
    key(current.address) {
        LiveStreamScreen(
            stream = current,
            hostName = profiles[current.hostPubkey]?.bestName,
            onBack = { LiveStreamRouter.close() },
        )
    }
}

/** A stream from a note-shaped event, as quotes store it; null for anything else. */
fun LiveStream.Companion.from(note: FeedNote): LiveStream? =
    if (note.kind == LiveStream.KIND) from(note.pubkey, note.createdAt.time / 1000, note.tags) else null

/**
 * A live stream inside a note — quoted with `nostr:naddr1…` or linked from
 * zap.stream and friends. The Live-tab look (frame, LIVE pill, viewers, title,
 * host), and a tap opens the same player. A stream that has ended shows ENDED,
 * dimmed, and does nothing. iOS: LiveStreamEmbedView.
 */
@Composable
fun LiveStreamEmbed(stream: LiveStream, modifier: Modifier = Modifier) {
    val nostrService = liveEmbedServices().nostrService()
    val profiles by nostrService.profiles.collectAsState()
    val host = profiles[stream.hostPubkey]
    LaunchedEffect(stream.hostPubkey) {
        if (host == null) nostrService.fetchMissingProfiles(listOf(stream.hostPubkey))
    }
    // Read once per composition: an embed scrolled back to after its stream
    // ended must stop offering to play it.
    val isLive = stream.isPlayableLive && stream.isOnAirAt(System.currentTimeMillis() / 1000)
    val hostName = host?.bestName ?: ("npub…" + stream.hostPubkey.takeLast(6))

    Surface(
        shape = RoundedCornerShape(12.dp),
        color = SecondaryGroupedBg,
        border = BorderStroke(0.5.dp, SeparatorColor),
        modifier = modifier
            .fillMaxWidth()
            .alpha(if (isLive) 1f else 0.75f)
            .semantics(mergeDescendants = true) {
                contentDescription = buildString {
                    append(if (isLive) "Live stream: " else "Ended stream: ")
                    append(stream.title ?: "Untitled stream")
                    append(", ")
                    append(hostName)
                }
            }
            .then(
                if (isLive) {
                    Modifier.clickable(role = Role.Button, onClickLabel = "Play the live stream") {
                        LiveStreamRouter.open(stream)
                    }
                } else {
                    Modifier
                },
            ),
    ) {
        Column {
            Box {
                LiveStreamThumbnail(
                    urls = stream.previewImageUrls,
                    modifier = Modifier.fillMaxWidth().height(170.dp),
                )
                Row(
                    verticalAlignment = Alignment.CenterVertically,
                    modifier = Modifier.padding(8.dp),
                ) {
                    if (isLive) LivePill() else EndedPill()
                    val participants = stream.participants
                    if (isLive && participants != null) {
                        Spacer(Modifier.width(6.dp))
                        Row(
                            verticalAlignment = Alignment.CenterVertically,
                            modifier = Modifier
                                .clip(CircleShape)
                                .background(Color.Black.copy(alpha = 0.55f))
                                .padding(horizontal = 6.dp, vertical = 3.dp),
                        ) {
                            Icon(Icons.Default.People, null, tint = Color.White, modifier = Modifier.size(11.dp))
                            Spacer(Modifier.width(3.dp))
                            Text("$participants", color = Color.White, fontSize = 10.sp, fontWeight = FontWeight.SemiBold)
                        }
                    }
                }
            }
            Column(modifier = Modifier.padding(10.dp)) {
                Text(
                    text = stream.title ?: "Untitled stream",
                    color = PrimaryText,
                    fontSize = 14.sp,
                    fontWeight = FontWeight.Bold,
                    maxLines = 2,
                    overflow = TextOverflow.Ellipsis,
                )
                Spacer(Modifier.height(4.dp))
                Text(text = hostName, color = SecondaryText, fontSize = 11.sp, maxLines = 1, overflow = TextOverflow.Ellipsis)
            }
        }
    }
}

@Composable
private fun LivePill() {
    Row(
        verticalAlignment = Alignment.CenterVertically,
        modifier = Modifier
            .clip(CircleShape)
            .background(Color.Black.copy(alpha = 0.55f))
            .padding(horizontal = 7.dp, vertical = 3.dp),
    ) {
        Box(Modifier.size(6.dp).clip(CircleShape).background(Color.Red))
        Spacer(Modifier.width(4.dp))
        Text("LIVE", color = Color.White, fontSize = 10.sp, fontWeight = FontWeight.Bold)
    }
}

@Composable
private fun EndedPill() {
    Text(
        text = "ENDED",
        color = Color.White.copy(alpha = 0.8f),
        fontSize = 10.sp,
        fontWeight = FontWeight.Bold,
        modifier = Modifier
            .clip(CircleShape)
            .background(Color.Black.copy(alpha = 0.55f))
            .padding(horizontal = 7.dp, vertical = 3.dp),
    )
}

/** How long a linked stream may take to arrive before the link card stands in. */
private const val STREAM_LOOKUP_GIVE_UP_MS = 15_000L

/**
 * The stream a web link names (`zap.stream/naddr1…` and the like), or null
 * when the link names none. iOS: QuoteReference.liveStreamCoordinate(in:).
 */
fun liveStreamCoordinate(url: String): String? =
    runCatching { QuoteRef.liveStreamCoordinate(url, HavenQuoteDecoder) }.getOrNull()

/**
 * A stream known only by its coordinate, as a link names it: fetched through
 * the same lookup quoted notes use, then embedded. If no relay has it, the
 * domain-only link card instead. iOS: LiveStreamReferenceView.
 */
@Composable
fun LiveStreamReferenceCard(coordinate: String, fallbackUrl: String, modifier: Modifier = Modifier) {
    val feedService = liveEmbedServices().feedService()
    val quoted by feedService.quotedNotes.collectAsState()
    val stream = remember(quoted[coordinate]) { quoted[coordinate]?.let { LiveStream.from(it) } }
    var gaveUp by remember(coordinate) { mutableStateOf(false) }
    LaunchedEffect(coordinate) {
        if (feedService.quotedNoteFor(coordinate) != null) return@LaunchedEffect
        feedService.fetchMissingQuotedNotes(listOf(coordinate))
        // Address lookups are never marked unavailable, so wait it out here.
        delay(STREAM_LOOKUP_GIVE_UP_MS)
        gaveUp = true
    }
    when {
        stream != null -> LiveStreamEmbed(stream, modifier)
        gaveUp -> LinkFallbackCard(fallbackUrl, modifier)
        else -> Box(
            modifier
                .fillMaxWidth()
                .height(230.dp)
                .clip(RoundedCornerShape(12.dp))
                .background(TertiaryGroupedBg),
        )
    }
}
