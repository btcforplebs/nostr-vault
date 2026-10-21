package com.nostrvault.ui.components

import androidx.compose.animation.core.Animatable
import androidx.compose.animation.core.spring
import androidx.compose.foundation.gestures.awaitEachGesture
import androidx.compose.foundation.gestures.awaitFirstDown
import androidx.compose.foundation.gestures.calculateCentroidSize
import androidx.compose.foundation.gestures.calculatePan
import androidx.compose.foundation.gestures.calculateZoom
import androidx.compose.foundation.gestures.detectTapGestures
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.BoxScope
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.runtime.*
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.geometry.Offset
import androidx.compose.ui.graphics.graphicsLayer
import androidx.compose.ui.input.pointer.pointerInput
import androidx.compose.ui.input.pointer.positionChanged
import androidx.compose.ui.layout.ContentScale
import androidx.compose.ui.layout.onSizeChanged
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.unit.IntSize
import coil.compose.AsyncImage
import coil.request.ImageRequest
import com.nostrvault.ui.theme.Motion
import kotlinx.coroutines.launch
import kotlin.math.abs
import kotlin.math.max
import kotlin.math.min

/**
 * Zoomable image for the media viewers: a [ZoomableBox] around the picture.
 */
@Composable
fun ZoomableImage(
    model: Any?,
    contentDescription: String?,
    modifier: Modifier = Modifier,
    onScaleChanged: ((Float) -> Unit)? = null,
    onVerticalDrag: ((Float) -> Unit)? = null,
    onVerticalDragEnd: ((Float) -> Unit)? = null,
    onLongPress: (() -> Unit)? = null,
) {
    val context = LocalContext.current
    ZoomableBox(
        modifier = modifier,
        onScaleChanged = onScaleChanged,
        onVerticalDrag = onVerticalDrag,
        onVerticalDragEnd = onVerticalDragEnd,
        onLongPress = onLongPress,
    ) {
        AsyncImage(
            model = ImageRequest.Builder(context)
                .data(model)
                // The feed's smaller copy, already in memory, stands in while
                // the full image loads — so the zoom from the feed never flies
                // an empty frame.
                .apply { (model as? String)?.let { placeholderMemoryCacheKey(it) } }
                .crossfade(true)
                .build(),
            contentDescription = contentDescription,
            contentScale = ContentScale.Fit,
            modifier = Modifier.fillMaxSize(),
        )
    }
}

/**
 * The media viewers' page gestures around [content], the same for a photo,
 * a video and an audio page (iOS `FeedMediaViewer` applies one set to all):
 *
 * - Pinch-to-zoom (1.0x to 3.0x) and double-tap between 1.0x and 2.0x, when [zoomable]
 * - Pan when zoomed with boundary clamping
 * - Releases horizontal gestures to HorizontalPager at 1.0x scale
 * - Releases horizontal gestures at zoom-pan edge for pager page change
 * - Reports vertical drag offset when at 1.0x for drag-to-dismiss
 * - [onTap] and [onLongPress], when given
 *
 * The box is the page's one reader of taps: [onTap] fires only once a tap is
 * known not to be the first of a double tap, and a long press is never also
 * a tap. So [content] must not take taps of its own over its whole area (a
 * video page hands the player's controls toggle up as [onTap]); its buttons
 * and seek bar consume theirs, so they never count here. Zoom resets when
 * [zoomable] turns false (a video going into picture-in-picture must not
 * carry the zoom into the window).
 *
 * All transforms are GPU-composited via graphicsLayer (zero extra bitmap allocation).
 */
@Composable
fun ZoomableBox(
    modifier: Modifier = Modifier,
    zoomable: Boolean = true,
    onScaleChanged: ((Float) -> Unit)? = null,
    onVerticalDrag: ((Float) -> Unit)? = null,
    onVerticalDragEnd: ((Float) -> Unit)? = null,
    onLongPress: (() -> Unit)? = null,
    onTap: (() -> Unit)? = null,
    content: @Composable BoxScope.() -> Unit,
) {
    val currentOnLongPress by rememberUpdatedState(onLongPress)
    val currentOnTap by rememberUpdatedState(onTap)
    val scope = rememberCoroutineScope()

    var scale by remember { mutableFloatStateOf(1f) }
    var offsetX by remember { mutableFloatStateOf(0f) }
    var offsetY by remember { mutableFloatStateOf(0f) }
    var containerSize by remember { mutableStateOf(IntSize.Zero) }

    val animOffsetX = remember { Animatable(0f) }
    val animOffsetY = remember { Animatable(0f) }
    val animScale = remember { Animatable(1f) }

    // Report scale changes to parent
    LaunchedEffect(scale) {
        onScaleChanged?.invoke(scale)
    }

    fun maxOffsetX(): Float = (containerSize.width * (scale - 1f)) / 2f
    fun maxOffsetY(): Float = (containerSize.height * (scale - 1f)) / 2f

    fun clampOffset(x: Float, y: Float): Pair<Float, Float> {
        val mx = maxOffsetX()
        val my = maxOffsetY()
        return x.coerceIn(-mx, mx) to y.coerceIn(-my, my)
    }

    fun resetToDefault() {
        scope.launch {
            launch { animScale.animateTo(1f, Motion.pick()) }
            launch { animOffsetX.animateTo(0f, Motion.pick()) }
            launch { animOffsetY.animateTo(0f, Motion.pick()) }
        }.invokeOnCompletion {
            scale = 1f
            offsetX = 0f
            offsetY = 0f
        }
    }

    /** Double tap: back to 1.0x, or 2.0x centred on [tapOffset]. */
    fun toggleZoom(tapOffset: Offset) {
        if (scale > 1.05f) {
            // Zoom out to 1.0x
            resetToDefault()
        } else {
            // Zoom in to 2.0x centered on tap point
            val targetScale = 2f
            val centeredX = (containerSize.width / 2f - tapOffset.x) * (targetScale - 1f)
            val centeredY = (containerSize.height / 2f - tapOffset.y) * (targetScale - 1f)
            val mx = (containerSize.width * (targetScale - 1f)) / 2f
            val my = (containerSize.height * (targetScale - 1f)) / 2f
            val clampedX = centeredX.coerceIn(-mx, mx)
            val clampedY = centeredY.coerceIn(-my, my)

            scope.launch {
                launch {
                    animScale.snapTo(scale)
                    animScale.animateTo(targetScale, Motion.pick())
                }
                launch {
                    animOffsetX.snapTo(offsetX)
                    animOffsetX.animateTo(clampedX, Motion.pick())
                }
                launch {
                    animOffsetY.snapTo(offsetY)
                    animOffsetY.animateTo(clampedY, Motion.pick())
                }
            }.invokeOnCompletion {
                scale = targetScale
                offsetX = clampedX
                offsetY = clampedY
            }
        }
    }

    // Out of zoom when it is turned off (picture-in-picture).
    LaunchedEffect(zoomable) {
        if (!zoomable && scale != 1f) {
            scale = 1f
            offsetX = 0f
            offsetY = 0f
        }
    }

    Box(
        contentAlignment = Alignment.Center,
        modifier = modifier
            .onSizeChanged { containerSize = it }
            // Tap, double-tap to zoom and long press. Keyed so a page without
            // a long-press or tap action never waits on one.
            .pointerInput(onLongPress != null, onTap != null, zoomable) {
                detectTapGestures(
                    onLongPress = if (onLongPress != null) { _ -> currentOnLongPress?.invoke() } else null,
                    onDoubleTap = if (zoomable) { tapOffset -> toggleZoom(tapOffset) } else null,
                    onTap = if (onTap != null) { _ -> currentOnTap?.invoke() } else null,
                )
            }
            // Pinch-to-zoom and pan
            .pointerInput(zoomable) {
                awaitEachGesture {
                    var zoom = 1f
                    var pastTouchSlop = false
                    val touchSlop = viewConfiguration.touchSlop

                    awaitFirstDown(requireUnconsumed = false)

                    do {
                        val event = awaitPointerEvent()
                        val canceled = event.changes.any { it.isConsumed }
                        if (canceled) break

                        if (event.changes.size >= 2 && zoomable) {
                            // Multi-touch: pinch-to-zoom + pan
                            val zoomChange = event.calculateZoom()
                            val panChange = event.calculatePan()

                            if (!pastTouchSlop) {
                                zoom *= zoomChange
                                val centroidSize = event.calculateCentroidSize(useCurrent = false)
                                if (abs(1 - zoom) * centroidSize > touchSlop) {
                                    pastTouchSlop = true
                                }
                            }

                            if (pastTouchSlop) {
                                val newScale = (scale * zoomChange).coerceIn(1f, 3f)
                                val (clampedX, clampedY) = clampOffset(
                                    offsetX + panChange.x,
                                    offsetY + panChange.y,
                                )
                                scale = newScale
                                offsetX = clampedX
                                offsetY = clampedY
                                onScaleChanged?.invoke(scale)

                                event.changes.forEach { if (it.positionChanged()) it.consume() }
                            }
                        } else if (event.changes.size == 1) {
                            // Single finger: pan when zoomed, or vertical drag for dismiss
                            val change = event.changes.first()
                            if (change.positionChanged()) {
                                val pan = change.position - change.previousPosition
                                if (scale > 1.05f) {
                                    // Panning zoomed image
                                    val mx = maxOffsetX()
                                    val my = maxOffsetY()

                                    // If at horizontal edge dragging further, don't consume
                                    // so HorizontalPager can handle page swipe
                                    val atLeftEdge = offsetX >= mx - 1f && pan.x > 0
                                    val atRightEdge = offsetX <= -mx + 1f && pan.x < 0

                                    if (!atLeftEdge && !atRightEdge) {
                                        val (clampedX, clampedY) = clampOffset(
                                            offsetX + pan.x,
                                            offsetY + pan.y,
                                        )
                                        offsetX = clampedX
                                        offsetY = clampedY
                                        change.consume()
                                    }
                                } else {
                                    // At 1.0x: only capture vertical drags for dismiss
                                    if (abs(pan.y) > abs(pan.x) * 1.5f) {
                                        onVerticalDrag?.invoke(pan.y)
                                        change.consume()
                                    }
                                    // Horizontal drags pass through to pager
                                }
                            }
                        }
                    } while (event.changes.any { it.pressed })

                    // Gesture ended
                    if (scale > 1.05f) {
                        // Snap to boundaries if needed
                        val (clampedX, clampedY) = clampOffset(offsetX, offsetY)
                        if (clampedX != offsetX || clampedY != offsetY) {
                            scope.launch {
                                launch { animOffsetX.snapTo(offsetX); animOffsetX.animateTo(clampedX, Motion.snapBack()) }
                                launch { animOffsetY.snapTo(offsetY); animOffsetY.animateTo(clampedY, Motion.snapBack()) }
                            }.invokeOnCompletion {
                                offsetX = clampedX
                                offsetY = clampedY
                            }
                        }
                    }

                    // If pinch ended below 1.0x, spring back
                    if (scale < 1f) {
                        resetToDefault()
                    }

                    // Notify parent that vertical drag ended (for dismiss decision)
                    onVerticalDragEnd?.invoke(0f)
                }
            }
            .graphicsLayer {
                scaleX = scale
                scaleY = scale
                translationX = offsetX
                translationY = offsetY
            },
    ) {
        content()
    }
}
