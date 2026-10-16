package com.nostrvault.ui.components

import kotlin.math.roundToInt
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.PaddingValues
import androidx.compose.foundation.layout.aspectRatio
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.padding
import androidx.compose.runtime.Composable
import androidx.compose.runtime.collectAsState
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clipToBounds
import androidx.compose.ui.graphics.Brush
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.unit.dp
import com.nostrvault.data.model.FeedProfile
import com.nostrvault.data.model.TrustMap
import com.nostrvault.data.model.TrustPath
import com.nostrvault.service.FeedService
import com.nostrvault.tutorials.TutorialContent
import com.nostrvault.tutorials.tutorialAnchor

/** Deep space behind the globe: dark whatever the app's appearance. */
private val SpaceTop = Color(red = 0.07f, green = 0.08f, blue = 0.13f)
internal val SpaceBrush = Brush.radialGradient(listOf(SpaceTop, Color.Black), radius = 2400f)

/** The globe's warm accent (iOS system orange) and the author's ring (yellow). */
internal val GlobeAccent = Color(0xFFFF9F0A)
internal val AuthorTint = Color(0xFFFFD60A)
internal val RingColor = Color(red = 0.72f, green = 0.82f, blue = 1f)
internal val HazeColor = Color(red = 0.62f, green = 0.55f, blue = 0.9f)
/** Warm amber for the threads, lighter than the glow behind them. */
internal val ThreadColor = Color(red = 1f, green = 0.66f, blue = 0.3f)

/**
 * The full globe shows about this many times [TrustMap]'s face counts: more
 * pictures overall, not quite double (Logen, 10/14). A slow phone's lite
 * globe keeps its own caps. iOS `TrustGlobeCanvas.faceScale`.
 */
internal const val GLOBE_FACE_SCALE = 1.8

internal fun globeFaces(count: Int): Int = (count * GLOBE_FACE_SCALE).roundToInt()

/** Bridges drawn as faces; the rest stay bright stars. */
internal val MAX_FACES = globeFaces(12)

@Composable
internal fun TrustWebViewGlobe(
    modifier: Modifier,
    /** Off on the WOT tab, where the globe runs to the screen's edges. */
    clip: Boolean = true,
    /** Keeps the pills and the trust card clear of the floating tab bar. */
    overlayPadding: PaddingValues = PaddingValues(0.dp),
    frame: TrustFrame?,
    centerKey: String,
    me: String,
    author: String,
    myFollows: Set<String>,
    haze: List<String>,
    closeHaze: Set<String>,
    lite: Boolean,
    ringFaces: List<String>,
    layerFaces: List<String>,
    /** Who the WOT tab's filters leave lit; null when none is on. */
    filterLit: Set<String>?,
    showingList: Boolean,
    isWOTTab: Boolean,
    layer: TrustMap.Layer,
    profiles: Map<String, FeedProfile>,
    name: (String) -> String,
    tapped: (String) -> Unit,
    card: String?,
    cardPath: TrustPath?,
    onEmptyTap: () -> Unit,
    followsPending: Boolean,
    mappingWeb: Boolean,
    accent: Color,
    onProfileClick: ((String) -> Unit)?,
    openProfile: (String) -> Unit,
    feedService: FeedService,
    closeCard: () -> Unit,
    onMessage: ((String) -> Unit)?,
    center: (String) -> Unit,
    /** Notes flying in as they reach the relay; null keeps the globe still (a post's globe, or the antenna off). */
    live: LiveArcsRequest? = null,
) {
    Box(if (clip) modifier.clipToBounds() else modifier) {
        TrustGlobe(
            frame = frame, center = centerKey, me = me, author = author, myFollows = myFollows, haze = haze,
            closeHaze = closeHaze,
            lite = lite,
            ringFaces = ringFaces,
            layerFaces = layerFaces,
            filterLit = if (isWOTTab) filterLit else null,
            running = !showingList,
            layer = if (isWOTTab && centerKey == me) layer else TrustMap.Layer.EVERYONE,
            summary = summary(frame, me, author, centerKey, name),
            profiles = profiles, name = name,
            onTap = tapped,
            // A tap on open space also puts the keyboard away.
            focus = card,
            focusBridges = cardPath?.all.orEmpty(),
            onEmptyTap = onEmptyTap,
            live = live,
            onNeedProfiles = { feedService.nostrService.fetchMissingProfiles(it) },
        )
        // The WoT tutorial's first card points at the middle of the
        // globe, you and the faces nearest you. The whole globe is nearly
        // the screen's height, which leaves the card no room beside it.
        if (isWOTTab) {
            Box(
                Modifier.align(Alignment.Center).fillMaxSize(0.6f).aspectRatio(1f)
                    .tutorialAnchor(TutorialContent.WOT_GLOBE),
            )
        }
        Box(Modifier.matchParentSize().padding(overlayPadding)) {
        when {
            // Someone tapped, their follow list still on its way.
            frame == null -> StatusPill(
                text = "Loading ${name(centerKey)}'s follows…",
                pubkey = centerKey, profile = profiles[centerKey], accent = accent,
                modifier = Modifier.align(Alignment.Center),
            )
            followsPending -> StatusPill(
                text = "Loading your follows…", accent = accent,
                modifier = Modifier.align(Alignment.Center),
            )
            // Your follows are in but the wider web (the haze) isn't yet.
            // The WOT tab says so in its live pill instead.
            !isWOTTab && mappingWeb && card == null ->
                StatusPill(
                    text = "Mapping your wider web…", accent = accent, small = true,
                    modifier = Modifier.align(Alignment.BottomCenter).padding(bottom = 12.dp),
                )
        }
        val followed by feedService.followedPubkeys.collectAsState()
        val shown = card
        if (shown != null) {
            // FeedService's list, the same one the card's path line is traced
            // from, so the button and "You follow them" can never disagree.
            val following = shown in followed
            var blocked by remember(shown) { mutableStateOf(feedService.isBlocked(shown)) }
            TrustCard(
                pubkey = shown,
                name = name,
                profiles = profiles,
                path = cardPath,
                following = following,
                blocked = blocked,
                accent = accent,
                onClose = closeCard,
                onFollow = { if (following) feedService.unfollowPubkey(shown) else feedService.followPubkey(shown) },
                onMessage = onMessage?.let { { it(shown) } },
                onProfile = onProfileClick?.let { { openProfile(shown) } },
                // Already in the middle: there's no further web to move to.
                onSeeWeb = if (shown == centerKey) null else { { closeCard(); center(shown) } },
                onBlock = {
                    if (blocked) feedService.unblockUser(shown) else { feedService.blockUser(shown); closeCard() }
                    blocked = !blocked
                },
                modifier = Modifier.align(Alignment.BottomCenter),
            )
        }
        }
    }
}

/** Read once per globe: [TrustMap.isLite] from this phone's memory. */
internal fun isLiteGlobe(context: android.content.Context): Boolean {
    val am = context.getSystemService(android.content.Context.ACTIVITY_SERVICE) as? android.app.ActivityManager
        ?: return false
    val info = android.app.ActivityManager.MemoryInfo().also(am::getMemoryInfo)
    return TrustMap.isLite(info.totalMem, am.isLowRamDevice)
}
