package com.nostrvault.ui.components

import androidx.compose.foundation.Canvas
import androidx.compose.foundation.border
import androidx.compose.foundation.gestures.awaitEachGesture
import androidx.compose.foundation.gestures.awaitFirstDown
import androidx.compose.foundation.gestures.calculatePan
import androidx.compose.foundation.gestures.calculateZoom
import androidx.compose.foundation.gestures.detectTapGestures
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.layout.only
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.SideEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.remember
import androidx.compose.runtime.rememberUpdatedState
import androidx.compose.runtime.setValue
import androidx.compose.runtime.snapshotFlow
import androidx.compose.runtime.withFrameNanos
import androidx.compose.ui.Modifier
import androidx.compose.ui.geometry.Offset
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.hapticfeedback.HapticFeedbackType
import androidx.compose.ui.input.pointer.pointerInput
import androidx.compose.ui.input.pointer.positionChanged
import androidx.compose.ui.input.pointer.util.VelocityTracker
import androidx.compose.ui.input.pointer.util.addPointerInputChange
import androidx.compose.ui.layout.Layout
import androidx.compose.ui.platform.LocalConfiguration
import androidx.compose.ui.platform.LocalHapticFeedback
import androidx.compose.ui.semantics.CustomAccessibilityAction
import androidx.compose.ui.semantics.clearAndSetSemantics
import androidx.compose.ui.semantics.contentDescription
import androidx.compose.ui.semantics.customActions
import androidx.compose.ui.semantics.stateDescription
import androidx.compose.ui.text.rememberTextMeasurer
import androidx.compose.ui.unit.Constraints
import androidx.compose.ui.unit.dp
import androidx.lifecycle.Lifecycle
import androidx.lifecycle.compose.LocalLifecycleOwner
import androidx.lifecycle.compose.currentStateAsState
import com.nostrvault.data.model.FeedProfile
import com.nostrvault.data.model.TrustMap
import com.nostrvault.ui.theme.Motion
import kotlinx.coroutines.delay
import kotlinx.coroutines.flow.drop
import kotlinx.coroutines.flow.first
import kotlin.math.max
import kotlin.math.roundToInt

// ── The globe ────────────────────────────────────────────────────────

/** Frame-clock seconds: the same base as `withFrameNanos`. */
internal fun nowSeconds() = System.nanoTime() / 1e9

/** What a globe reload depends on; any change re-settles it. */
private data class LoadKey(
    val center: String,
    val ring: Int,
    val bridges: Int,
    val chains: Int,
    val haze: Int,
    val close: Int,
    val mine: Int,
    /** Who is in the ring, not just how many: a follow and an unfollow together keep the count. */
    val ringHash: Int,
    /** Who is in the haze: past its cap, a newcomer swaps in for someone at the margin and the count stays put. */
    val hazeHash: Int,
    /** The ring's faces when the core is the author; they change as pictures stream in. */
    val faces: List<String>,
    /** The picked layer's faces on the outer shell. */
    val layerFaces: List<String>,
)

/** Spinning and turning to a person both take about this long; a new person's globe settles in after it. */
private const val TURN_DELAY_MS = 380L

/** Pictures are laid out at this size and scaled to each face. */
private const val PICTURE_DP = 64f

/**
 * The globe itself: one Canvas for stars and threads, the few faces on top as
 * pictures, and a second Canvas for names. A frame clock runs only while
 * something on it moves.
 */
@Composable
internal fun TrustGlobe(
    frame: TrustFrame?,
    center: String,
    me: String,
    author: String,
    myFollows: Set<String>,
    haze: List<String>,
    /** The part of [haze] at least [TrustMap.CLOSE_VOUCHES] of your follows follow. */
    closeHaze: Set<String> = emptySet(),
    /** A phone with little memory: stars are drawn as points. */
    lite: Boolean,
    /**
     * Faces for the ring when the core is the author, who has no bridges to
     * show: without these the only face is the core ([TrustMap.pickFaces]).
     */
    ringFaces: List<String>,
    /** Pictures on the outer shell for the picked layer (Close or Further out), on your own globe. */
    layerFaces: List<String> = emptyList(),
    /** Who the WOT tab's filters leave lit; the rest dim. Null when no filter is on. */
    filterLit: Set<String>? = null,
    /** False while a sheet covers the globe: the clock stops. */
    running: Boolean,
    /** Which part of the web is lit (the WOT tab's layer picker). */
    layer: TrustMap.Layer = TrustMap.Layer.EVERYONE,
    /** The person the trust card is about: the globe turns to face them. */
    focus: String? = null,
    /** The people you follow who follow [focus]: its threads run through them. */
    focusBridges: List<String> = emptyList(),
    summary: String,
    profiles: Map<String, FeedProfile>,
    name: (String) -> String,
    onTap: (String) -> Unit,
    /** A tap that lands on no one, e.g. to close the peek card. */
    onEmptyTap: () -> Unit,
    /** The WOT tab's live arrivals; null for none (a post's globe never has them). */
    live: LiveArcsRequest? = null,
    /** The WOT tab's globe keeps drifting while on screen; a post's sleeps after a while. */
    keepsDrifting: Boolean = false,
    /** Pictures still missing for people the globe shows. */
    onNeedProfiles: (List<String>) -> Unit = {},
) {
    val phone = LocalConfiguration.current.smallestScreenWidthDp < 600
    val scene = remember(phone) { GlobeScene(lite, phone) }
    val textMeasurer = rememberTextMeasurer(cacheSize = 128)
    val haptic = LocalHapticFeedback.current
    val lifecycleState by LocalLifecycleOwner.current.lifecycle.currentStateAsState()
    val active = running && lifecycleState.isAtLeast(Lifecycle.State.RESUMED)
    val currentFrame by rememberUpdatedState(frame)
    val currentHaze by rememberUpdatedState(haze)
    val currentCloseHaze by rememberUpdatedState(closeHaze)
    val currentRingFaces by rememberUpdatedState(ringFaces)
    val currentLayerFaces by rememberUpdatedState(layerFaces)
    val currentLayer by rememberUpdatedState(layer)
    val currentFollows by rememberUpdatedState(myFollows)
    val currentName by rememberUpdatedState(name)
    val currentOnTap by rememberUpdatedState(onTap)
    val currentOnEmptyTap by rememberUpdatedState(onEmptyTap)

    SideEffect {
        if (scene.camera.keepsDrifting != keepsDrifting) {
            scene.camera.keepsDrifting = keepsDrifting
            scene.wake()
        }
    }

    // The frame clock: runs while awake and on screen, then sleeps until a
    // touch or new data wakes it. Keyed on [active] only: a wake landing before
    // the next recomposition would leave an `awake` key unchanged.
    LaunchedEffect(active) {
        if (!active) return@LaunchedEffect
        while (true) {
            snapshotFlow { scene.awake }.first { it }
            scene.lastTick = null
            while (scene.awake) {
                val started = withFrameNanos { scene.tick(it / 1e9); it }
                // No finger on it: 60 fps in a storm, else 30, rather than every frame keeps the phone cool.
                val frameMs = scene.frameRate.frameMs
                if (frameMs > 0) delay(max(0L, frameMs - (System.nanoTime() - started) / 1_000_000))
            }
        }
    }

    // Live arrivals: the stream runs while the globe is on screen; off clears the lines.
    LaunchedEffect(live, active) {
        scene.setLiveArcs(live != null && active)
        if (live == null || !active) return@LaunchedEffect
        live.stream.arrivals(live.me, live.rings, live.show).collect { arrival ->
            if (live.show.allows(arrival.sort)) scene.arrive(arrival)
        }
    }

    // Pictures for who just got a face, an arc's end among them.
    val currentProfiles by rememberUpdatedState(profiles)
    LaunchedEffect(scene) {
        snapshotFlow { scene.faceKeys }.collect { keys ->
            val missing = keys.filter { currentProfiles[it] == null }
            if (missing.isNotEmpty()) onNeedProfiles(missing)
        }
    }

    LaunchedEffect(center) {
        if (scene.hasLoaded && center != scene.center) scene.turn(center)
    }

    LaunchedEffect(layer) { scene.focus(layer) }

    LaunchedEffect(filterLit) { scene.filter(filterLit) }

    LaunchedEffect(focus) { focus?.let { scene.turn(it) } }

    LaunchedEffect(focus, focusBridges) { scene.trace(focus, focusBridges) }

    // Reduce Motion turned off while the clock sleeps: nothing else wakes it.
    LaunchedEffect(scene) {
        Motion.reducedUpdates.drop(1).collect { scene.reduceMotionChanged() }
    }

    val loadKey = frame?.let {
        LoadKey(it.center, it.ring.size, it.bridges.size, it.chains?.size ?: -1, haze.size, closeHaze.size,
            myFollows.size, it.ring.hashCode(), haze.hashCode(), if (it.center == author) ringFaces else emptyList(),
            layerFaces)
    }
    LaunchedEffect(loadKey) {
        val first = currentFrame ?: return@LaunchedEffect
        // Turn to the new person first, then let the globe re-settle around them.
        if (scene.hasLoaded && first.center != scene.center && !Motion.isReduced) delay(TURN_DELAY_MS)
        val latest = currentFrame ?: return@LaunchedEffect
        scene.load(latest, me, author, currentFollows, currentHaze, currentCloseHaze, currentRingFaces,
            currentLayerFaces, currentLayer)
    }

    val faceKeys = scene.faceKeys
    val accent = GlobeAccent
    Box(
        Modifier
            .fillMaxSize()
            .pointerInput(scene) {
                // A double-tap resets; a single tap waits until it can't be one,
                // so a double-tap on a face doesn't also fly there.
                detectTapGestures(
                    onDoubleTap = { scene.reset() },
                    onTap = { at ->
                        val key = scene.hit(at, size.width.toFloat(), size.height.toFloat(), density)
                        if (key == null) {
                            currentOnEmptyTap()
                        } else {
                            haptic.performHapticFeedback(HapticFeedbackType.TextHandleMove)
                            currentOnTap(key)
                        }
                    },
                )
            }
            .pointerInput(scene) {
                // One finger spins, two pinch. Taps fall through to the detector
                // above until a finger moves past the touch slop.
                awaitEachGesture {
                    val down = awaitFirstDown(requireUnconsumed = false)
                    // The first finger only, release included, so a pause
                    // before lifting lets go with no flick.
                    val tracker = VelocityTracker()
                    tracker.addPointerInputChange(down)
                    var moving = false
                    var pinched = false
                    var travel = Offset.Zero
                    try {
                        while (true) {
                            val event = awaitPointerEvent()
                            event.changes.firstOrNull { it.id == down.id }?.let { tracker.addPointerInputChange(it) }
                            val pressed = event.changes.count { it.pressed }
                            if (pressed == 0) break
                            val zoom = event.calculateZoom()
                            val pan = event.calculatePan()
                            if (pressed > 1) pinched = true
                            if (!moving) {
                                travel += pan
                                moving = pressed > 1 || travel.getDistance() > viewConfiguration.touchSlop
                            }
                            if (!moving) continue
                            val now = nowSeconds()
                            if (pressed > 1) {
                                if (zoom != 1f) scene.camera.zoomBy(zoom.toDouble(), now)
                            } else {
                                scene.camera.dragging = true
                                scene.camera.drag(pan.x / density.toDouble(), pan.y / density.toDouble(), now)
                            }
                            event.changes.forEach { if (it.positionChanged()) it.consume() }
                            scene.wake()
                        }
                        if (moving && !pinched) {
                            val v = tracker.calculateVelocity()
                            scene.camera.flick(v.x / density.toDouble(), v.y / density.toDouble(), nowSeconds(), Motion.isReduced)
                        }
                    } finally {
                        // Also on cancel, or the camera would think it's still held.
                        scene.camera.dragging = false
                        scene.wake()
                    }
                }
            }
            .clearAndSetSemantics {
                contentDescription = "Web of Trust globe"
                stateDescription = summary
                customActions = faceKeys.filter { it != center }.map { key ->
                    CustomAccessibilityAction("Go to ${name(key)}") { currentOnTap(key); true }
                } + listOf(
                    CustomAccessibilityAction("Zoom in") { scene.zoomStep(0.3); true },
                    CustomAccessibilityAction("Zoom out") { scene.zoomStep(-0.3); true },
                    CustomAccessibilityAction("Reset view") { scene.reset(); true },
                )
            },
    ) {
        Canvas(Modifier.fillMaxSize()) { scene.drawBack(this, accent) }

        Layout(
            content = {
                for (key in faceKeys) {
                    androidx.compose.runtime.key(key) {
                        val tint = when {
                            key == center && key == me -> accent
                            key == center -> Color.White
                            key == (scene.traceTarget ?: author) -> AuthorTint
                            key in scene.arcOnlyKeys -> GlobeSceneArcs.FaceTint
                            // The core is the author: these are their follows.
                            center == author && scene.traceTarget == null -> RingColor
                            else -> accent
                        }
                        val profile = profiles[key]
                        AvatarImage(
                            url = profile?.pictureURL,
                            pubkey = key,
                            size = PICTURE_DP.dp,
                            displayName = profile?.bestName,
                            modifier = Modifier.border(4.dp, tint, CircleShape),
                        )
                    }
                }
            },
            modifier = Modifier.fillMaxSize(),
        ) { measurables, constraints ->
            val placeables = measurables.map { it.measure(Constraints()) }
            layout(constraints.maxWidth, constraints.maxHeight) {
                scene.prepare(constraints.maxWidth.toFloat(), constraints.maxHeight.toFloat(), density)
                placeables.forEachIndexed { i, placeable ->
                    val spot = faceKeys.getOrNull(i)?.let(scene::spot)
                    val half = placeable.width / 2f
                    if (spot == null || spot.ember) {
                        placeable.placeWithLayer(0, 0) { alpha = 0f }
                    } else {
                        val s = (spot.r / half).toFloat()
                        placeable.placeWithLayer(
                            (spot.x - half).roundToInt(),
                            (spot.y - placeable.height / 2f).roundToInt(),
                            zIndex = if (spot.core) 10f else spot.depth.toFloat(),
                        ) {
                            scaleX = s
                            scaleY = s
                            alpha = spot.alpha.toFloat()
                        }
                    }
                }
            }
        }

        Canvas(Modifier.fillMaxSize()) { scene.drawLabels(this, textMeasurer, currentName) }
    }
}
