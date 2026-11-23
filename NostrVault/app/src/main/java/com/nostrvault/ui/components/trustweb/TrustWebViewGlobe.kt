package com.nostrvault.ui.components

import kotlin.math.roundToInt
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.PaddingValues
import androidx.compose.foundation.layout.aspectRatio
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.width
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
import com.nostrvault.ui.theme.AppPalette

/** Deep space behind the globe in Dark. */
private val SpaceTop = Color(red = 0.07f, green = 0.08f, blue = 0.13f)
private val DarkSpace = Brush.radialGradient(listOf(SpaceTop, Color.Black), radius = 2400f)

/** Light: a late-morning sky, pale blue overhead to a warm haze low down. */
private val SkyHigh = Color(0xFFA7CDEE)
private val SkyMid = Color(0xFFD3E5F2)
internal val SkyLow = Color(0xFFF4E8D8)
private val DaySky = Brush.verticalGradient(0f to SkyHigh, 0.55f to SkyMid, 1f to SkyLow)

/**
 * The Web of Trust always draws Dark (Logen 2026-11-16): the daytime sky is
 * kept but unused. Set true to bring it back for anyone who chose Light.
 */
private val GLOBE_DAY_SKY = false

/** The globe draws a daytime sky only when [GLOBE_DAY_SKY] is on and the user chose Light. */
internal val globeDay: Boolean get() = GLOBE_DAY_SKY && AppPalette.lightChosen

/** What fills behind the globe: deep space in Dark, the sky in Light. */
internal val SpaceBrush: Brush get() = if (globeDay) DaySky else DarkSpace
internal val SpaceBase: Color get() = if (globeDay) SkyLow else Color.Black

/** The globe's warm accent (iOS system orange) and the author's ring (yellow); deeper by day to read on the sky. */
internal val GlobeAccent: Color get() = if (globeDay) Color(0xFFE5730A) else Color(0xFFFF9F0A)
internal val AuthorTint: Color get() = if (globeDay) Color(0xFFD9A400) else Color(0xFFFFD60A)
internal val RingColor: Color get() = if (globeDay) Color(0xFF2F6CB3) else Color(red = 0.72f, green = 0.82f, blue = 1f)
internal val HazeColor: Color get() = if (globeDay) Color(0xFF6A62A8) else Color(red = 0.62f, green = 0.55f, blue = 0.9f)
/** Your mutuals' stars: white in space, a slate blue by day. */
internal val MutualStar: Color get() = if (globeDay) Color(0xFF2E3B4E) else Color.White
/** Warm amber for the threads, lighter than the glow behind them (deeper by day). */
internal val ThreadColor: Color get() = if (globeDay) Color(0xFFCF6A14) else Color(red = 1f, green = 0.66f, blue = 0.3f)
/** The core's name under it. */
internal val GlobeLabel: Color get() = if (globeDay) Color(0xFF1E2733) else Color.White

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
    /** The people list or My Web covers it: no clock, no live connections (iOS `running`). */
    paused: Boolean,
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
    /** Wide WOT tab: the card docks down the trailing side instead of across the bottom. */
    cardAsSidePanel: Boolean = false,
    /** Their wider web is on its way, for someone else in the middle. */
    mappingWider: Boolean = false,
    /** A profile's or a post's globe: the card's one button, which shows them in the WOT tab. */
    onOpenInWot: ((String) -> Unit)? = null,
) {
    Box(if (clip) modifier.clipToBounds() else modifier) {
        TrustGlobe(
            frame = frame, center = centerKey, me = me, author = author, myFollows = myFollows, haze = haze,
            closeHaze = closeHaze,
            lite = lite,
            ringFaces = ringFaces,
            layerFaces = layerFaces,
            filterLit = if (isWOTTab) filterLit else null,
            running = !paused,
            layer = if (isWOTTab && centerKey == me) layer else TrustMap.Layer.EVERYONE,
            summary = summary(frame, me, author, centerKey, name),
            profiles = profiles, name = name,
            onTap = tapped,
            // A tap on open space also puts the keyboard away.
            focus = card,
            focusBridges = cardPath?.all.orEmpty(),
            onEmptyTap = onEmptyTap,
            live = live,
            keepsDrifting = isWOTTab,
            onNeedProfiles = { feedService.nostrService.fetchMissingProfiles(it) },
            showsOuterRings = isWOTTab && centerKey == me,
        )
        // The WoT tutorial's first card points at the middle of the
        // globe, you and the faces nearest you. The whole globe is nearly
        // the screen's height, which leaves the card no room beside it.
        if (isWOTTab) {
            Box(
                Modifier.align(Alignment.Center).fillMaxSize(0.5f).aspectRatio(1f)
                    .tutorialAnchor(TutorialContent.WOT_GLOBE),
            )
        }
        Box(Modifier.matchParentSize().padding(overlayPadding)) {
        when {
            // Moving onto someone keeps the globe up: the trail's chip spins
            // instead. Only the very first globe has nothing to show (iOS).
            frame == null && centerKey == me -> StatusPill(
                text = "Loading ${name(centerKey)}'s follows…",
                pubkey = centerKey, profile = profiles[centerKey],
                modifier = Modifier.align(Alignment.Center),
            )
            followsPending -> StatusPill(
                text = "Loading your follows…", pubkey = me, profile = profiles[me],
                modifier = Modifier.align(Alignment.Center),
            )
            // Your follows are in but the wider web (the haze) isn't yet.
            // The WOT tab says so in its live pill instead.
            !isWOTTab && mappingWeb && card == null ->
                StatusPill(
                    text = "Mapping your wider web…",
                    modifier = Modifier.align(Alignment.BottomCenter).padding(bottom = 14.dp),
                )
            mappingWider && card == null ->
                StatusPill(
                    text = "Mapping ${name(centerKey)}'s web…",
                    pubkey = centerKey, profile = profiles[centerKey],
                    modifier = Modifier.align(Alignment.BottomCenter).padding(bottom = 14.dp),
                )
        }
        if (isWOTTab && centerKey == me && card == null && frame != null && !followsPending && !mappingWeb) {
            GlobeOuterRingsBar(
                accent = accent, profiles = profiles,
                onNeedProfiles = { feedService.nostrService.fetchMissingProfiles(it) },
                onPick = tapped,
                // Above the My Web button, which sits on the bottom edge.
                modifier = Modifier.align(Alignment.BottomStart).padding(start = 16.dp, end = 16.dp, bottom = 76.dp),
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
                onOpenInWot = onOpenInWot?.let { open -> { open(shown) } },
                modifier = if (cardAsSidePanel) Modifier.align(Alignment.TopEnd).width(SIDE_PANEL_WIDTH)
                else Modifier.align(Alignment.BottomCenter),
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
