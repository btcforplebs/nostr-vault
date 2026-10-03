package com.nostrvault.ui.components

import androidx.compose.runtime.Composable
import androidx.compose.runtime.DisposableEffect
import androidx.compose.runtime.collectAsState
import androidx.compose.runtime.getValue
import androidx.compose.ui.Modifier
import androidx.compose.ui.graphics.graphicsLayer
import androidx.compose.ui.layout.boundsInWindow
import androidx.compose.ui.layout.onGloballyPositioned
import androidx.compose.ui.layout.positionInWindow
import java.util.concurrent.atomic.AtomicLong
import kotlin.math.max
import kotlin.math.min

/**
 * The zoom from a photo's spot in the feed to the full-screen viewer and back —
 * the Android half of iOS #117 (`.navigationTransition(.zoom)` sourced from
 * `matchedTransitionSource`).
 *
 * The viewer lives in [FullScreenMediaHost] at the activity root, outside the
 * NavHost, so Compose's shared-element scopes (which need one
 * `SharedTransitionLayout` around both ends and an `AnimatedVisibility` scope
 * at each) don't reach it. Instead every tappable photo reports where it sits
 * on screen to [MediaZoomSources], and the viewer animates its own content
 * from that rect to full screen and back.
 */

/** A plain rect, so the geometry below stays testable without Compose. */
internal data class ZoomRect(val left: Float, val top: Float, val width: Float, val height: Float) {
    val centerX: Float get() = left + width / 2f
    val centerY: Float get() = top + height / 2f
    val area: Float get() = max(width, 0f) * max(height, 0f)

    fun offset(dx: Float, dy: Float) = ZoomRect(left + dx, top + dy, width, height)
}

/** Scale about the container's top-left, then translate. Identity is (1, 0, 0). */
internal data class ZoomTransform(val scale: Float, val translationX: Float, val translationY: Float) {
    companion object {
        val Identity = ZoomTransform(1f, 0f, 0f)
    }
}

internal object MediaZoomGeometry {

    /** Below this share of its area on screen, a source has scrolled away: fade instead. */
    const val MIN_VISIBLE_FRACTION = 0.3f

    /** Where a [aspect] (w/h) image lands when drawn `Fit` in a container, centred. */
    fun fit(aspect: Float, containerWidth: Float, containerHeight: Float): ZoomRect {
        if (aspect <= 0f || !aspect.isFinite() || containerWidth <= 0f || containerHeight <= 0f) {
            return ZoomRect(0f, 0f, containerWidth, containerHeight)
        }
        val containerAspect = containerWidth / containerHeight
        return if (aspect > containerAspect) {
            val h = containerWidth / aspect
            ZoomRect(0f, (containerHeight - h) / 2f, containerWidth, h)
        } else {
            val w = containerHeight * aspect
            ZoomRect((containerWidth - w) / 2f, 0f, w, containerHeight)
        }
    }

    /**
     * The transform that puts [fitted] (the image as the viewer draws it) over
     * [source] (the image's spot in the feed). [crop] for a source that fills
     * its box (the Media grid's square cells): the image covers the rect and
     * the clip trims it. Otherwise it fits inside, as the feed card draws it.
     */
    fun transform(fitted: ZoomRect, source: ZoomRect, crop: Boolean): ZoomTransform {
        if (fitted.width <= 0f || fitted.height <= 0f) return ZoomTransform.Identity
        val sx = source.width / fitted.width
        val sy = source.height / fitted.height
        val s = if (crop) max(sx, sy) else min(sx, sy)
        if (s <= 0f || !s.isFinite()) return ZoomTransform.Identity
        return ZoomTransform(
            scale = s,
            translationX = source.centerX - fitted.centerX * s,
            translationY = source.centerY - fitted.centerY * s,
        )
    }

    /** [from] at progress 0, identity at 1. Not clamped, so a spring's overshoot carries through. */
    fun interpolate(from: ZoomTransform, progress: Float): ZoomTransform = ZoomTransform(
        scale = lerp(from.scale, 1f, progress),
        translationX = lerp(from.translationX, 0f, progress),
        translationY = lerp(from.translationY, 0f, progress),
    )

    /** [rect] (container coordinates) expressed in the layer's own, untransformed coordinates. */
    fun toLocal(rect: ZoomRect, t: ZoomTransform): ZoomRect = ZoomRect(
        left = (rect.left - t.translationX) / t.scale,
        top = (rect.top - t.translationY) / t.scale,
        width = rect.width / t.scale,
        height = rect.height / t.scale,
    )

    fun lerpRect(a: ZoomRect, b: ZoomRect, progress: Float): ZoomRect {
        val p = progress.coerceIn(0f, 1f)
        return ZoomRect(
            lerp(a.left, b.left, p),
            lerp(a.top, b.top, p),
            lerp(a.width, b.width, p),
            lerp(a.height, b.height, p),
        )
    }

    /**
     * Whether a source is still on screen enough to zoom into. [visible] is its
     * rect after clipping by every ancestor (the list viewport, the window).
     */
    fun isOnScreen(full: ZoomRect, visible: ZoomRect): Boolean =
        full.area > 0f && visible.area >= full.area * MIN_VISIBLE_FRACTION

    private fun lerp(a: Float, b: Float, t: Float) = a + (b - a) * t
}

/** One photo's spot: which row of media ([origin]) and which item in it. */
data class MediaSourceKey(val origin: Long, val index: Int)

/** Where a source sits in the window, and how it draws its image. */
internal data class MediaSourceBounds(val full: ZoomRect, val visible: ZoomRect, val crop: Boolean)

/** Live window positions of every photo that can open the viewer. */
internal object MediaZoomSources {
    private val nextOrigin = AtomicLong(1)
    private val bounds = HashMap<MediaSourceKey, MediaSourceBounds>()

    /** A fresh id for one row/grid of media; `remember` it at the call site. */
    fun newOrigin(): Long = nextOrigin.getAndIncrement()

    @Synchronized
    fun put(key: MediaSourceKey, value: MediaSourceBounds) {
        bounds[key] = value
    }

    @Synchronized
    fun remove(key: MediaSourceKey) {
        bounds.remove(key)
    }

    @Synchronized
    fun get(key: MediaSourceKey): MediaSourceBounds? = bounds[key]
}

/**
 * Marks this node as the spot [key]'s photo zooms out of and back into. It
 * reports its window rect while composed, and goes invisible while the viewer
 * is drawing its image over it, so the photo doesn't appear twice mid-flight.
 */
@Composable
internal fun Modifier.mediaZoomSource(key: MediaSourceKey, crop: Boolean = false): Modifier {
    DisposableEffect(key) {
        onDispose { MediaZoomSources.remove(key) }
    }
    val hidden by FullScreenMediaRouter.hiddenSource.collectAsState()
    return this
        .onGloballyPositioned { coords ->
            val pos = coords.positionInWindow()
            val vis = coords.boundsInWindow()
            MediaZoomSources.put(
                key,
                MediaSourceBounds(
                    full = ZoomRect(pos.x, pos.y, coords.size.width.toFloat(), coords.size.height.toFloat()),
                    visible = ZoomRect(vis.left, vis.top, vis.width, vis.height),
                    crop = crop,
                ),
            )
        }
        .graphicsLayer { alpha = if (hidden == key) 0f else 1f }
}
