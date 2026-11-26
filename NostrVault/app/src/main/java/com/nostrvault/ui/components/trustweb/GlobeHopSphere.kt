package com.nostrvault.ui.components

import android.graphics.Paint
import androidx.compose.ui.geometry.Offset
import androidx.compose.ui.graphics.Brush
import androidx.compose.ui.graphics.drawscope.DrawScope
import androidx.compose.ui.graphics.drawscope.Stroke
import androidx.compose.ui.graphics.drawscope.drawIntoCanvas
import androidx.compose.ui.graphics.nativeCanvas
import androidx.compose.ui.graphics.toArgb
import com.nostrvault.data.model.GlobeEdge
import com.nostrvault.data.model.GlobeSphereField
import com.nostrvault.data.model.TrustMap
import com.nostrvault.data.model.TrustMapOuter
import com.nostrvault.data.model.Vec3
import kotlin.math.hypot
import kotlin.math.max
import kotlin.math.min
import kotlin.math.roundToInt

/**
 * Draws a picked hop as its own globe ([GlobeSphereField], Logen 2026-11-25):
 * the ring's top 300 as bright stars, the best of them on the front as faces
 * you can tap, and its haze ([TrustMapOuter.Ring.haze]) as faint dust over the
 * rest of the surface. It turns with the inner globe's camera, so one drag
 * spins both. The inner globe stays in the middle, shrunk inside it
 * ([com.nostrvault.data.model.GlobeRingZoom.nest]), and its faces keep clear
 * of the inner globe so that stays in view and tappable. Picking a hop
 * further out nests this sphere in turn, smaller and fainter.
 *
 * [prepare] works one frame out (dots, faces, taps) once, for the canvas and
 * for the face layout; positions are built once per ring and pole. The canvas
 * draws on the main thread only. iOS `Views/TrustWeb/GlobeHopSphere.swift`.
 */
internal object GlobeHopSphere {
    /** A face's radius on the front of a fitted sphere, dp: the inner globe's ring faces' size. */
    const val FACE_SIZE = 11.0
    /** Faces show over the whole side facing you and fade toward the rim, where the inner globe's do. */
    val FACE_FROM = (1 + GlobeEdge.FACE_GONE) / 2
    val FACE_FULL = (1 + GlobeEdge.FACE_FULL) / 2
    /** A picked sphere's radius on a phone at zoom 1, dp (the Hop 2 globe's outline): faces and dots are drawn their own size there. */
    private const val FITTED_SIZE = 193.0
    /** Brightness steps per kind of dot, so 2,000 dots are a few native calls. */
    private const val LEVELS = 12
    /** Size steps per brightness step: the near side is drawn a little bigger. */
    private const val SIZES = 3
    /** A point counts as coming round from here (front 0 is the back). */
    const val WINDOW_FROM = 0.3
    /** The window is sent on at most this often while the sphere turns, seconds. */
    const val WINDOW_EVERY = 0.4
    /** The nested globe's faces reach past its outline to its outer shells: the hole the picked sphere leaves for it. */
    const val HOLE_REACH = 1.1

    /** As many faces at once as the inner globe shows on its ring, so the sphere reads as the same kind of globe. */
    fun maxFaces(lite: Boolean): Int =
        if (lite) TrustMap.RING_FACES_LITE else (TrustMap.RING_FACES * GLOBE_FACE_SCALE).roundToInt()

    /** Whose profiles the picked sphere asks for: its whole top, so faces come in all the way round. */
    fun pictureKeys(ring: TrustMapOuter.Ring): List<String> = ring.top

    // ── Positions ──

    private class Built(val top: List<String>, val haze: List<String>, val pole: Vec3, val points: DoubleArray)
    private data class Slot(val hop: Int, val first: String, val count: Int)
    private val built = HashMap<Slot, Built>()
    private const val MAX_SLOTS = 8

    private fun points(ring: TrustMapOuter.Ring, pole: Vec3): Built {
        val slot = Slot(ring.hop, ring.top.firstOrNull() ?: "", ring.top.size + ring.haze.size)
        built[slot]?.let { b -> if (b.pole == pole && b.top == ring.top && b.haze == ring.haze) return b }
        val b = Built(ring.top, ring.haze, pole, GlobeSphereField.points(ring.top + ring.haze, ring.top.size, pole))
        if (built.size >= MAX_SLOTS) built.clear()
        built[slot] = b
        return b
    }

    // ── One frame ──

    /** A sphere to draw this frame: [shown] how strongly, [picked] how much it is the picked hop. */
    class Placed(val ring: TrustMapOuter.Ring, val centre: Offset, val r: Double, val shown: Double, val picked: Double)

    /** A face on screen: where, its radius in px, and how strongly. */
    class Face(val x: Double, val y: Double, val r: Double, val alpha: Double)

    private class Target(val key: String, val x: Double, val y: Double, val reach: Double)

    /** Dots, by kind (0 haze, 1 top), brightness and size step, as x, y pairs. */
    private val buckets = Array(2) { Array(LEVELS + 1) { Array(SIZES) { FloatBuffer() } } }
    private val sizeOf = Array(2) { DoubleArray(SIZES) }
    private var bodies: List<Placed> = emptyList()
    private val faces = HashMap<String, Face>()
    private var targets: List<Target> = emptyList()
    private var hole: Triple<Double, Double, Double>? = null
    private var lastPicked: Built? = null
    /** Who held a face last frame: they keep it while they still fit, so faces do not swap as the sphere turns. */
    private var seated: Set<String> = emptySet()
    private var facing: Set<String> = emptySet()
    private var windowSent: Set<String> = emptySet()
    private var windowSentAt = Double.NEGATIVE_INFINITY
    private var preparedFor: Any? = null

    /** Each sphere drawn this frame (picked and nested), by hop, so a path can find where someone on it is ([screenPoint]). */
    private class Drawn(val built: Built, val centre: Offset, val r: Double, val m: DoubleArray)
    private val drawn = HashMap<Int, Drawn>()

    /** A spot on screen, with how far toward you (0 back, 1 front). */
    class Point(val x: Double, val y: Double, val front: Double)

    /**
     * Where [key] is on screen on the hop [hop] sphere worked out last (any
     * sphere when null). Null when they are on none. iOS `GlobeHopSphere.screenPoint`.
     */
    fun screenPoint(key: String, hop: Int?): Point? {
        for ((h, d) in drawn) {
            if (hop != null && hop != h) continue
            val top = d.built.top.indexOf(key)
            val i = if (top >= 0) top else d.built.haze.indexOf(key).takeIf { it >= 0 }?.plus(d.built.top.size) ?: continue
            val p = d.built.points
            val m = d.m
            val x = p[3 * i]; val y = p[3 * i + 1]; val z = p[3 * i + 2]
            val q = GlobeSphereField.project(m[0] * x + m[1] * y + m[2] * z, m[3] * x + m[4] * y + m[5] * z, m[6] * x + m[7] * y + m[8] * z)
            return Point(d.centre.x + q.x * d.r, d.centre.y + q.y * d.r, q.front)
        }
        return null
    }

    /** The face for [key] this frame, or null when they have no seat. */
    fun face(key: String): Face? = faces[key]

    /** The new picture window when it changed since the last one sent and that was long enough ago; null otherwise. */
    fun windowIfChanged(now: Double): List<String>? {
        if (facing == windowSent || now - windowSentAt < WINDOW_EVERY) return null
        windowSent = facing
        windowSentAt = now
        return facing.toList()
    }

    /** Clears the frame: no sphere is up. */
    fun clear() {
        for (k in buckets) for (l in k) for (s in l) s.count = 0
        bodies = emptyList()
        faces.clear()
        targets = emptyList()
        hole = null
        lastPicked = null
        facing = emptySet()
        drawn.clear()
    }

    /**
     * Works out this frame for [spheres] (inner first) turned by [m] (the
     * camera's row-major turn), once per [frameKey]. [pictures] are who may
     * show a face (picture in), [focus] the trust card's person, whose face
     * always takes a seat. [holeAt] is the nested inner globe's disc: no face
     * is seated and no star tapped inside it.
     */
    fun prepare(
        frameKey: Any, spheres: List<Placed>, m: DoubleArray, pole: Vec3, pictures: Set<String>,
        focus: String?, holeAt: Triple<Double, Double, Double>?, density: Float, lite: Boolean,
    ) {
        if (frameKey == preparedFor) return
        preparedFor = frameKey
        clear()
        bodies = spheres
        hole = holeAt
        fun clear(x: Double, y: Double): Boolean =
            holeAt == null || hypot(x - holeAt.first, y - holeAt.second) >= holeAt.third
        val tapTargets = ArrayList<Target>()
        for (s in spheres) {
            val ring = s.ring
            if (s.shown <= 0.01 || s.r <= 4 || (ring.top.isEmpty() && ring.haze.isEmpty())) continue
            val b = points(ring, pole)
            drawn[ring.hop] = Drawn(b, s.centre, s.r, m)
            val isPicked = s.picked > 0.5
            if (isPicked) lastPicked = b
            val back = 0.55 + 0.45 * s.picked
            val zoomed = min(1.8, max(0.7, s.r / (FITTED_SIZE * density)))
            val topCount = b.top.size
            val fronts = DoubleArray(topCount)
            val candidates = ArrayList<Candidate>()
            val wantFaces = s.picked > 0.3
            val p = b.points
            for (i in 0 until p.size / 3) {
                val x = p[3 * i]; val y = p[3 * i + 1]; val z = p[3 * i + 2]
                val tx = m[0] * x + m[1] * y + m[2] * z
                val ty = m[3] * x + m[4] * y + m[5] * z
                val tz = m[6] * x + m[7] * y + m[8] * z
                val q = GlobeSphereField.project(tx, ty, tz)
                val f = GlobeSphereField.facing(tx, ty, tz)
                val ax = s.centre.x + q.x * s.r
                val ay = s.centre.y + q.y * s.r
                val isTop = i < topCount
                val kind = if (isTop) 1 else 0
                val a = if (isTop) (0.25 + 0.65 * q.front) * s.shown * back else (0.06 + 0.22 * q.front) * s.shown * back
                val base = (if (isTop) 2.1 else 1.2) * zoomed * back * density
                if (isTop) {
                    fronts[i] = f
                    val key = b.top[i]
                    if (wantFaces && key in pictures && f >= FACE_FROM) candidates += Candidate(key, ax, ay, FACE_SIZE * density * q.scale * zoomed, f, i)
                    if (isPicked && f > 0.55 && clear(ax, ay)) tapTargets += Target(key, ax, ay, 14.0 * density)
                }
                val level = (min(1.0, a) * LEVELS).roundToInt()
                if (level <= 0) continue
                // q.scale runs about 0.77 (back) to 1.42 (front).
                val step = ((q.scale - 0.77) / 0.65 * SIZES).toInt().coerceIn(0, SIZES - 1)
                sizeOf[kind][step] = base * (0.77 + 0.65 * (step + 0.5) / SIZES)
                buckets[kind][min(LEVELS, level)][step].add(ax.toFloat(), ay.toFloat())
            }
            if (isPicked) {
                facing = GlobeSphereField.window(fronts, FACE_FROM, WINDOW_FROM, maxFaces(lite), maxFaces(lite) / 2)
                    .mapTo(HashSet()) { b.top[it] }
            }
            if (!wantFaces || candidates.isEmpty()) continue
            // Front-most first, so the nearest win a seat; no face covers another.
            candidates.sortByDescending { it.front }
            val spots = candidates.map { TrustMap.FaceSpot(it.key, it.x, it.y, it.r) }
            val always = focus?.let { setOf(it) } ?: emptySet()
            val blocked = holeAt?.let { listOf(TrustMap.FaceSpot("", it.first, it.second, it.third)) } ?: emptyList()
            val rank = candidates.associate { it.key to it.rank }
            val seats = TrustMap.seatFaces(spots, always, seated, blocked)
                .sortedWith(compareBy<String>({ it !in always }, { rank[it] ?: Int.MAX_VALUE }))
                .take(maxFaces(lite)).toHashSet()
            if (isPicked) seated = seats
            for (c in candidates) {
                if (c.key !in seats) continue
                val o = GlobeEdge.smoothstep(FACE_FROM, FACE_FULL, c.front) * min(1.0, (s.picked - 0.3) / 0.5) * s.shown
                if (o <= 0.01) continue
                val fr = GlobeEdge.faceRadius(c.r, o / max(s.shown, 0.01))
                faces[c.key] = Face(c.x, c.y, fr, o)
                if (isPicked && o > 0.5) tapTargets += Target(c.key, c.x, c.y, max(24.0 * density, c.r + 8 * density))
            }
        }
        targets = tapTargets
    }

    private class Candidate(val key: String, val x: Double, val y: Double, val r: Double, val front: Double, val rank: Int)

    private val paint = Paint(Paint.ANTI_ALIAS_FLAG).apply { strokeCap = Paint.Cap.ROUND }

    /** Paints this frame's spheres: a faint glass ball and outline each, then the dots. Faces are pictures laid over it. */
    fun draw(scope: DrawScope) = with(scope) {
        for (s in bodies) {
            if (s.shown <= 0.01 || s.r <= 4) continue
            val r = s.r.toFloat()
            drawCircle(
                Brush.radialGradient(
                    listOf(HazeColor.copy(alpha = (0.14 * s.shown).toFloat()), HazeColor.copy(alpha = (0.03 * s.shown).toFloat())),
                    center = Offset(s.centre.x - r * 0.3f, s.centre.y - r * 0.35f), radius = r * 1.2f,
                ),
                radius = r, center = s.centre,
            )
            drawCircle(HazeColor.copy(alpha = (0.08 * s.shown).toFloat()), radius = r, center = s.centre, style = Stroke(0.6f * density))
        }
        drawIntoCanvas { c ->
            val canvas = c.nativeCanvas
            for ((kind, color) in listOf(0 to HazeColor, 1 to RingColor)) {
                for (level in 1..LEVELS) for (step in 0 until SIZES) {
                    val buf = buckets[kind][level][step]
                    if (buf.count == 0) continue
                    paint.strokeWidth = (2 * sizeOf[kind][step]).toFloat()
                    paint.color = color.copy(alpha = level.toFloat() / LEVELS).toArgb()
                    canvas.drawPoints(buf.data, 0, buf.count * 2, paint)
                }
            }
        }
    }

    // ── Taps ──

    /** Whether a tap lands on the nested inner globe. */
    fun inHole(x: Float, y: Float): Boolean {
        val h = hole ?: return false
        return hypot(x - h.first, y - h.second) < h.third
    }

    /** The face (or, failing that, front star) of the picked sphere under a tap, from the frame last worked out. */
    fun hit(x: Float, y: Float): String? {
        var best: String? = null
        var bestD = Double.MAX_VALUE
        for (t in targets) {
            val d = hypot(t.x - x, t.y - y)
            if (d < t.reach && d < bestD) { best = t.key; bestD = d }
        }
        return best
    }

    /** Where [key] sits on the picked sphere, in the globe's own space: the globe turns this to the front when their card opens. */
    fun direction(key: String): Vec3? {
        val b = lastPicked ?: return null
        val i = b.top.indexOf(key)
        if (i < 0) return null
        return Vec3(b.points[3 * i], b.points[3 * i + 1], b.points[3 * i + 2]).normalized()
    }

    /** A growable x, y float list reused frame to frame. */
    private class FloatBuffer {
        var data = FloatArray(64)
        var count = 0
        fun add(x: Float, y: Float) {
            if (2 * count + 2 > data.size) data = data.copyOf(data.size * 2)
            data[2 * count] = x
            data[2 * count + 1] = y
            count++
        }
    }
}
