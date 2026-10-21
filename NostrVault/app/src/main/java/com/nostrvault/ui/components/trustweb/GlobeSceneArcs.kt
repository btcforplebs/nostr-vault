package com.nostrvault.ui.components

import androidx.compose.ui.graphics.Color
import com.nostrvault.data.model.GlobeArcs
import com.nostrvault.data.model.GlobeEdge
import com.nostrvault.data.model.GlobeStorm
import com.nostrvault.data.model.TrustMap
import com.nostrvault.data.model.Vec3
import kotlin.math.min

/**
 * The globe's live arrivals between frames (iOS GlobeScene's live-arcs part):
 * the board of lines, whose ends get pictures, and the painter. Lives on the
 * frame clock's thread, the main one; arrivals reach it there.
 */
internal class GlobeSceneArcs {
    val board = GlobeArcs.Board()
    val painter = LiveArcsPainter()
    var on = false
        private set
    /** People pictured at the ends of the newest lines. */
    var keys: List<String> = emptyList()
        private set
    /** When the faces last changed: in a storm at most every [GlobeStorm.FACE_REFRESH]. */
    private var keysSynced = Double.NEGATIVE_INFINITY
    private var keysStale = false

    val idle: Boolean get() = board.isIdle
    val busy: Boolean get() = board.isBusy

    /** Turns the arcs on or off; off clears what is on the globe. True when anything changed. */
    fun setOn(value: Boolean): Boolean {
        if (value == on) return false
        on = value
        if (!value) {
            board.clear()
            keys = emptyList()
        }
        return true
    }

    /** Lets waiting arrivals fly and drops what faded. True when the pictured people changed. */
    fun step(now: Double, me: String, center: String): Boolean {
        val before = board.lines.size
        val released = board.step(now, me)
        if (board.lines.size != before || released.isNotEmpty()) keysStale = true
        if (!keysStale || (board.isBusy && now - keysSynced < GlobeStorm.FACE_REFRESH)) return false
        keysStale = false
        keysSynced = now
        val next = board.faceKeys(GlobeStorm.MAX_ARC_FACES, except = center)
        if (next == keys) return false
        keys = next
        return true
    }

    /**
     * Where each pictured end of a line sits this frame, easing in as its star
     * sets out and out as its light fades; one rolling toward the rim fades and
     * shrinks rather than popping. Faces already seated by the globe keep theirs.
     */
    fun faceSpots(
        now: Double,
        project: (Vec3) -> GlobeScene.Projected?,
        place: (String, GlobeArcs.Ring?) -> Vec3,
        seated: Set<String>,
        center: String,
        radius: (GlobeScene.Projected) -> Double,
    ): List<GlobeScene.Spot> {
        if (keys.isEmpty()) return emptyList()
        val pictured = keys.toHashSet()
        val shown = HashMap<String, Double>()
        val setsOut = HashMap<String, GlobeArcs.Ring>()
        for (line in board.lines) {
            if (line.from !in pictured && line.to !in pictured) continue
            val a = GlobeArcs.faceAlpha(line, now)
            for (key in arrayOf(line.from, line.to)) if (a > (shown[key] ?: 0.0)) shown[key] = a
            setsOut.putIfAbsent(line.from, line.ring)
        }
        val out = ArrayList<GlobeScene.Spot>()
        for ((key, alpha) in shown) {
            if (key == center || key in seated || key !in pictured || alpha <= 0.02) continue
            val p = project(place(key, setsOut[key])) ?: continue
            val edge = GlobeEdge.face(p.depth)
            if (edge <= 0.02) continue
            out += GlobeScene.Spot(
                key, p.x, p.y, GlobeEdge.faceRadius(radius(p), edge), alpha * edge * (0.4 + 0.6 * p.front), p.depth,
                ember = false, core = false, tint = FaceTint,
            )
        }
        return out
    }

    companion object {
        /** A face at a line's end: white, like the stars that fly to it. */
        val FaceTint = Color.White.copy(alpha = 0.85f)

        /** The face radius for a line's end, in pixels, as iOS sizes it (13 at k = 1). */
        fun faceRadius(p: GlobeScene.Projected, k: Double, zoom: Double, density: Float) =
            13 * k * p.scale * min(zoom, 1.8) * density
    }
}

/** A note reached the relay: it takes its turn on the globe. */
internal fun GlobeScene.arrive(arrival: GlobeArcs.Arrival) {
    if (!arcs.on || !hasLoaded) return
    arcs.board.add(arrival)
    wake()
}

/**
 * Where someone sits for an arc. A star from your follows sets out from their
 * own star on the ring; one from Discover or Global from that feed's shell, in
 * their direction. Anyone else sits on their star, or on the outer shell.
 */
internal fun GlobeScene.arcPoint(key: String, setsOutFrom: GlobeArcs.Ring?): Vec3 {
    if (setsOutFrom != null && setsOutFrom != GlobeArcs.Ring.FOLLOWING) return TrustMap.direction(key) * setsOutFrom.radius
    index[key]?.takeIf { it.alpha > 0.05 }?.let { return it.dir * it.radius }
    return TrustMap.direction(key) * TrustMap.OUTER_RADIUS
}
