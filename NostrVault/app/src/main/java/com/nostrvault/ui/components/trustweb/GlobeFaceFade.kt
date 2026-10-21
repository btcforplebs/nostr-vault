package com.nostrvault.ui.components

import com.nostrvault.data.model.GlobeEdge
import kotlin.math.abs
import kotlin.math.exp

/**
 * How a face fades at the globe's rim and when it loses its seat (iOS
 * `GlobeEdge.seat` and the face loop of `GlobeScene.draw`). Rolling toward the
 * rim a face fades and shrinks onto the ember it is round the back; losing its
 * seat to a neighbour it cross-fades with the star it becomes. Nothing switches.
 */
internal object GlobeFaceFade {
    /** Below this a face's picture is not drawn at all (iOS `shown > 0.01`). */
    const val PICTURE_MIN = 0.01
    /** At or above this the ember under a face is not drawn (iOS `shown < 0.99`). */
    const val EMBER_MAX = 0.99

    /** A seat's fade, eased toward [seated] over about a quarter second. Reduce Motion cuts. */
    fun seat(current: Double, seated: Boolean, dt: Double, reduceMotion: Boolean): Double {
        val target = if (seated) 1.0 else 0.0
        if (reduceMotion) return target
        val next = current + (target - current) * (1 - exp(-dt * 12))
        return if (abs(target - next) < 0.01) target else next
    }

    /** How much of the face at [depth] shows: the author always whole, others by [GlobeEdge.face]. */
    fun edge(depth: Double, isAuthor: Boolean) = if (isAuthor) 1.0 else GlobeEdge.face(depth)

    /** The ember's radius in iOS points before density: 3.2 round the back, 3.6 in front. */
    fun emberRadius(edge: Double, scale: Double, zoom: Double) = (3.2 + 0.4 * edge) * scale * zoom

    /** The ember's opacity under a face that is [shown] of the way in; 0 once the face is whole. */
    fun emberAlpha(dim: Double, shown: Double) = if (shown < EMBER_MAX) dim * (1 - shown) else 0.0

    /** The picture's opacity; 0 while it is too faint to draw. */
    fun pictureAlpha(dim: Double, shown: Double) = if (shown > PICTURE_MIN) dim * shown else 0.0
}

/**
 * Each face's seat fade between frames (iOS `seatFade`). Entries are kept and
 * updated in place, so a warm frame allocates nothing; a face not drawn in a
 * frame is forgotten, as iOS replaces its map.
 */
internal class GlobeSeatFades {
    private class Fade(var value: Double, var frame: Long)

    private val fades = HashMap<String, Fade>()
    private var frame = 0L

    /** True while some face is still fading in or out: the frame clock stays up. */
    var fading = false
        private set

    /** Starts a frame's pass. */
    fun begin() {
        frame++
        fading = false
    }

    /** Steps [key]'s fade toward [seated] and returns it. A face new to the globe starts where it is heading. */
    fun step(key: String, seated: Boolean, dt: Double, reduceMotion: Boolean): Double {
        val target = if (seated) 1.0 else 0.0
        val fade = fades[key]
        val current = if (fade == null || fade.frame < frame - 1) target else fade.value
        val next = GlobeFaceFade.seat(current, seated, dt, reduceMotion)
        if (fade == null) fades[key] = Fade(next, frame) else { fade.value = next; fade.frame = frame }
        if (next != target) fading = true
        return next
    }

    /** Ends the pass: drops faces that have been off the globe a while, so the map stays small. */
    fun end() {
        if (fades.size > SWEEP_AT) fades.values.removeAll { it.frame != frame }
    }

    private companion object {
        /** Faces drawn at once are a few dozen; past this many entries, sweep the stale ones. */
        const val SWEEP_AT = 256
    }
}
