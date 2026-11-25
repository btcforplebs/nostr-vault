package com.nostrvault.ui.components

import android.graphics.Paint
import android.os.Handler
import android.os.Looper
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.setValue
import androidx.compose.ui.geometry.Offset
import androidx.compose.ui.graphics.Brush
import androidx.compose.ui.graphics.drawscope.DrawScope
import androidx.compose.ui.graphics.drawscope.Stroke
import androidx.compose.ui.graphics.drawscope.drawIntoCanvas
import androidx.compose.ui.graphics.nativeCanvas
import androidx.compose.ui.graphics.toArgb
import com.nostrvault.data.model.GlobeCamera
import com.nostrvault.data.model.GlobeEdge
import com.nostrvault.data.model.GlobeRingZoom
import com.nostrvault.data.model.GlobeSphereField
import com.nostrvault.data.model.TrustMap
import com.nostrvault.data.model.TrustMapOuter
import com.nostrvault.data.model.Vec3
import kotlin.math.hypot
import kotlin.math.max
import kotlin.math.min
import kotlin.math.roundToInt

/**
 * A picked hop drawn as its own globe ([GlobeSphereField], Logen 2026-11-25):
 * the ring's top 300 as bright stars, the best of them on the side facing you
 * as faces you can tap, and its haze ([com.nostrvault.data.model.TrustRankCopy.haze])
 * as faint dust over the rest of the surface. It turns with the inner globe's
 * camera, so one drag spins both. The inner globe stays in the middle, shrunk
 * inside it ([GlobeRingZoom.nest]), and the sphere's faces keep clear of it so
 * it stays in view and tappable. Picking a hop further out nests this sphere
 * in turn, smaller and fainter, round the inner globe.
 *
 * One per globe. [prepare] works a frame out once (the face layout and both
 * canvases ask); positions are built once per ring and pole, so a frame turns
 * ~2,000 points into a few native drawPoints calls. Faces are the globe's own
 * [AvatarImage]s, placed by [GlobeHopSphereLayer].
 * iOS `Views/TrustWeb/GlobeHopSphere.swift`.
 */
internal class GlobeHopSphere {
    companion object {
        /** A face's radius on the front of a fitted sphere, dp: the inner globe's ring faces' size. */
        const val FACE_SIZE = 11.0
        /**
         * As many faces at once as iOS seats ([TrustMap.RING_FACES] times its
         * face scale), so the sphere reads as full (Logen 2026-11-25:
         * "populate photos all around it"); fewer on a lite phone.
         */
        const val MAX_FACES = 72
        const val MAX_FACES_LITE = TrustMap.RING_FACES
        /** Pictures kept ready past the seated ones, for faces coming round. */
        const val COMING = 24
        /** Faces show over the whole side facing you and fade toward the rim, where the inner globe's do. */
        val FACE_FROM = (1 + GlobeEdge.FACE_GONE) / 2
        val FACE_FULL = (1 + GlobeEdge.FACE_FULL) / 2
        /** A point counts as coming round from here (front 0 is the back). */
        const val WINDOW_FROM = 0.3
        /** The pictures composed change at most this often while the sphere turns, seconds. */
        const val WINDOW_EVERY = 0.25
        /** A picked sphere's radius on a phone at zoom 1, dp: faces and dots are drawn their own size there and grow with a pinch. */
        private const val FITTED_SIZE = 170.0
        /** Brightness steps per kind of dot. */
        private const val LEVELS = 16
        /** The nested globe's faces reach past its outline to its outer shells: the hole the picked sphere leaves for it. */
        const val HOLE_REACH = 1.1
    }

    /** A face this frame, in pixels. */
    class Face(val key: String, val x: Double, val y: Double, val r: Double, val alpha: Double, val front: Double)

    /** Who has a picture composed ([GlobeHopSphereLayer]): the seated faces, then those coming round. */
    var pictures by mutableStateOf(emptyList<String>())
        private set
    private var picturesSentAt = Double.NEGATIVE_INFINITY
    private val main = Handler(Looper.getMainLooper())

    private class Built(val top: List<String>, val haze: List<String>, val pole: Vec3, val points: DoubleArray)
    private val built = HashMap<Int, Built>()

    private fun points(ring: TrustMapOuter.Ring, pole: Vec3): Built {
        built[ring.hop]?.let { b ->
            if (b.pole == pole && (b.top === ring.top || b.top == ring.top) && (b.haze === ring.haze || b.haze == ring.haze)) {
                return if (b.top === ring.top && b.haze === ring.haze) b
                else Built(ring.top, ring.haze, pole, b.points).also { built[ring.hop] = it }
            }
        }
        return Built(ring.top, ring.haze, pole, GlobeSphereField.points(ring.top + ring.haze, pole)).also { built[ring.hop] = it }
    }

    // ── One frame ──

    private class Target(val key: String, val x: Double, val y: Double, val reach: Double)
    private class Placed(val built: Built, val cx: Double, val cy: Double, val r: Double, val m: DoubleArray)

    private class Bucket(val top: Boolean, val level: Int, val color: Int, val diameter: Float) {
        var xy = FloatArray(64)
        var count = 0
        fun add(x: Float, y: Float) {
            if (count * 2 + 2 > xy.size) xy = xy.copyOf(xy.size * 2)
            xy[count * 2] = x
            xy[count * 2 + 1] = y
            count++
        }
    }

    private class Body(val cx: Float, val cy: Float, val r: Float, val shown: Float)

    private var frameKey: List<Any?>? = null
    private val targets = ArrayList<Target>()
    private val placed = HashMap<Int, Placed>()
    private val bodies = ArrayList<Body>()
    private val buckets = HashMap<Long, Bucket>()
    private val bucketOrder = ArrayList<Bucket>()
    /** This frame's faces, front-most last so they draw on top. */
    var faces: List<Face> = emptyList()
        private set
    private val faceByKey = HashMap<String, Face>()
    /** Who held a face last frame: they keep it while they still fit, so faces do not swap as the sphere turns. */
    private var seated: Set<String> = emptySet()
    private var hole: Triple<Double, Double, Double>? = null
    private var lastPicked: Built? = null
    private val q = DoubleArray(4)
    private val paint = Paint(Paint.ANTI_ALIAS_FLAG).apply {
        strokeCap = Paint.Cap.ROUND
        style = Paint.Style.STROKE
    }

    fun face(key: String): Face? = faceByKey[key]

    /**
     * Works out this frame's spheres for a [w]×[h] pixel view: the picked hop
     * and any picked before it now nested in it, turned by [camera]. Runs once
     * per frame however often it's asked. [hasPicture] says whose picture is
     * known: only they get a face, never a lettered stand-in. [focus] is the
     * trust card's person: their face always takes a seat.
     */
    fun prepare(
        outer: TrustMapOuter, camera: GlobeCamera, level: Double, center: String, w: Float, h: Float, density: Float,
        phone: Boolean, lite: Boolean, focus: String?, hasPicture: (String) -> Boolean,
    ) {
        val key = listOf(camera.orientation, camera.zoom, level, w, h, outer, focus, center, pictures)
        if (key == frameKey) return
        frameKey = key
        targets.clear(); placed.clear(); bodies.clear(); faceByKey.clear()
        for (b in bucketOrder) b.count = 0
        faces = emptyList()
        hole = null
        lastPicked = null
        if (level <= 0.001 || outer.isFaint) return
        val wd = w.toDouble(); val hd = h.toDouble()
        val base = GlobeOuterRings.outline(wd, hd, camera.zoom, phone)
        if (!base.isFinite()) return
        val grow = GlobeOuterRings.pinch(wd, hd, camera.zoom, phone)
        val m = camera.orientation.matrix()
        val pole = GlobeSphereField.pole(center)
        // The inner globe's disc, with room for its outer shell's faces.
        val globe = GlobeOuterRings.place(TrustMapOuter.FIRST_HOP - 1, level, base, wd, hd, grow)
        val holeNow = Triple(globe.centre.x.toDouble(), globe.centre.y.toDouble(), globe.r * HOLE_REACH)
        val composed = pictures.toHashSet()
        val coming = ArrayList<Pair<String, Double>>()
        val candidates = ArrayList<Face>()
        val rank = HashMap<String, Int>()
        var faceShown = 0.0
        var facePicked = 0.0
        // Inner first, so the picked one is drawn over what is nested in it.
        for (ring in outer.rings) {
            val sphere = GlobeRingZoom.sphere(ring.hop, level)
            val pickedD = GlobeRingZoom.emphasis(ring.hop, level)
            val shown = GlobeRingZoom.visibility(ring.hop, level) * sphere * GlobeOuterRings.fadeFor(ring.hop, pickedD.toFloat())
            if (shown <= 0.01 || (ring.top.isEmpty() && ring.haze.isEmpty())) continue
            val at = GlobeOuterRings.place(ring.hop, level, base, wd, hd, grow)
            val r = at.r
            if (r <= 4 * density) continue
            val cx = at.centre.x.toDouble(); val cy = at.centre.y.toDouble()
            val b = points(ring, pole)
            placed[ring.hop] = Placed(b, cx, cy, r, m)
            bodies += Body(at.centre.x, at.centre.y, r.toFloat(), shown.toFloat())
            val picked = pickedD
            if (picked > 0.5) {
                lastPicked = b
                hole = holeNow
            }
            // A sphere nested inside a later pick steps back: smaller, fainter dots.
            val back = 0.55 + 0.45 * picked
            val zoomed = min(1.8, max(0.7, r / (FITTED_SIZE * density)))
            val topCount = b.top.size
            val count = if (lite) min(b.points.size / 3, topCount + TrustMap.HAZE_CAP_LITE) else b.points.size / 3
            val seats = picked > 0.3
            for (i in 0 until count) {
                val px = b.points[3 * i]; val py = b.points[3 * i + 1]; val pz = b.points[3 * i + 2]
                GlobeSphereField.project(
                    m[0] * px + m[1] * py + m[2] * pz, m[3] * px + m[4] * py + m[5] * pz, m[6] * px + m[7] * py + m[8] * pz, q,
                )
                val x = cx + q[0] * r; val y = cy + q[1] * r
                val front = q[3]
                val isTop = i < topCount
                val a: Double; val size: Double
                if (isTop) {
                    a = (0.25 + 0.65 * front) * shown * back
                    size = 2.1 * q[2] * zoomed * back
                } else {
                    a = (0.06 + 0.22 * front) * shown * back
                    size = 1.2 * q[2] * zoomed * back
                }
                if (isTop && seats) {
                    val k = b.top[i]
                    if (front >= WINDOW_FROM && hasPicture(k)) {
                        if (front >= FACE_FROM) {
                            candidates += Face(k, x, y, FACE_SIZE * density * q[2] * zoomed, 0.0, front)
                            rank[k] = i
                        } else coming += k to front
                    }
                    if (picked > 0.5 && front > 0.55 && clear(x, y, 0.0, holeNow)) targets += Target(k, x, y, 14.0 * density)
                }
                val level16 = (min(1.0, a) * LEVELS).roundToInt()
                if (level16 <= 0) continue
                bucket(isTop, min(LEVELS, level16), size * 2 * density).add(x.toFloat(), y.toFloat())
            }
            if (seats) { faceShown = shown; facePicked = picked }
        }
        if (candidates.isEmpty()) {
            seated = emptySet()
            publish(emptyList())
            return
        }
        // Front-most first, so the nearest win a seat; no face covers another.
        candidates.sortByDescending { it.front }
        val always = focus?.let { setOf(it) } ?: emptySet()
        val spots = candidates.map { TrustMap.FaceSpot(it.key, it.x, it.y, it.r) }
        val blocked = hole?.let { listOf(TrustMap.FaceSpot("", it.first, it.second, it.third)) } ?: emptyList()
        val max = if (lite) MAX_FACES_LITE else MAX_FACES
        // The best-ranked of those that fit keep a face, up to max.
        val seats = TrustMap.seatFaces(spots, always, seated, blocked)
            .sortedWith(compareBy<String>({ if (it in always) 0 else 1 }, { rank[it] ?: Int.MAX_VALUE }))
            .take(max).toHashSet()
        seated = seats
        val out = ArrayList<Face>(seats.size)
        for (c in candidates.asReversed()) {
            if (c.key !in seats) continue
            val o = GlobeEdge.smoothstep(FACE_FROM, FACE_FULL, c.front) * min(1.0, (facePicked - 0.3) / 0.5) * faceShown
            if (o <= 0.01) continue
            val fr = GlobeEdge.faceRadius(c.r, o / max(faceShown, 0.01))
            val f = Face(c.key, c.x, c.y, fr, o, c.front)
            if (c.key in composed) {
                out += f
                faceByKey[c.key] = f
                if (o > 0.5) targets += Target(c.key, c.x, c.y, max(24.0 * density, c.r + 8 * density))
            }
        }
        faces = out
        coming.sortByDescending { it.second }
        publish(seats.sortedBy { rank[it] ?: Int.MAX_VALUE } + coming.asSequence().map { it.first }.filter { it !in seats }.take(COMING))
    }

    /** The pictures to compose, sent on at most every [WINDOW_EVERY] (from the main looper, not mid-frame). */
    private fun publish(keys: List<String>) {
        if (keys == pictures) return
        val now = nowSeconds()
        if (now - picturesSentAt < WINDOW_EVERY && keys.isNotEmpty()) return
        picturesSentAt = now
        main.post { pictures = keys }
    }

    private fun clear(x: Double, y: Double, pad: Double, hole: Triple<Double, Double, Double>) =
        hypot(x - hole.first, y - hole.second) >= hole.third + pad

    private fun bucket(top: Boolean, level: Int, diameterPx: Double): Bucket {
        val d = max(1, diameterPx.roundToInt()).coerceAtMost(255)
        val key = (if (top) 1L shl 32 else 0L) or (level.toLong() shl 16) or d.toLong()
        return buckets.getOrPut(key) {
            val base = if (top) RingColor else HazeColor
            Bucket(top, level, base.copy(alpha = level.toFloat() / LEVELS).toArgb(), d.toFloat()).also {
                bucketOrder += it
                // Haze under the top, each dim to bright, so a bright star sits on top.
                bucketOrder.sortWith(compareBy({ b -> b.top }, { b -> b.level }, { b -> b.diameter }))
            }
        }
    }

    /** Draws this frame's spheres: each body as a faint glass ball and its outline, then its dots. */
    fun draw(scope: DrawScope) = with(scope) {
        for (b in bodies) {
            val c = Offset(b.cx, b.cy)
            drawCircle(
                Brush.radialGradient(
                    listOf(HazeColor.copy(alpha = 0.14f * b.shown), HazeColor.copy(alpha = 0.03f * b.shown)),
                    center = Offset(b.cx - b.r * 0.3f, b.cy - b.r * 0.35f), radius = b.r * 1.2f,
                ),
                radius = b.r, center = c,
            )
            drawCircle(HazeColor.copy(alpha = 0.08f * b.shown), radius = b.r, center = c, style = Stroke(width = 0.6f * density))
        }
        if (bucketOrder.none { it.count > 0 }) return@with
        drawIntoCanvas { canvas ->
            val native = canvas.nativeCanvas
            for (b in bucketOrder) {
                if (b.count == 0) continue
                paint.color = b.color
                paint.strokeWidth = b.diameter
                native.drawPoints(b.xy, 0, b.count * 2, paint)
            }
        }
    }

    // ── Taps and paths ──

    /** The face (or, failing that, front star) of the picked sphere under a tap, from the frame last worked out. Null when nothing is near, or no hop sphere is up. */
    fun hit(at: Offset): String? {
        var best: String? = null
        var bestD = Double.MAX_VALUE
        for (t in targets) {
            val d = hypot(t.x - at.x, t.y - at.y)
            if (d < t.reach && d < bestD) { best = t.key; bestD = d }
        }
        return best
    }

    /** Whether a tap lands on the nested inner globe: there the globe's own faces come first. */
    fun inHole(at: Offset): Boolean = hole?.let { hypot(at.x - it.first, at.y - it.second) < it.third } ?: false

    /** Where [key] sits on the picked sphere, in the globe's own space: the globe turns this to the front when their card opens. Null when they are not on it. */
    fun direction(key: String): Vec3? {
        val b = lastPicked ?: return null
        val i = b.top.indexOf(key).takeIf { it >= 0 } ?: return null
        return Vec3(b.points[3 * i], b.points[3 * i + 1], b.points[3 * i + 2])
    }

    /** Where [key] is on screen on the [hop] sphere worked out last frame (any sphere when null), with its 0-1 front. */
    fun screenPoint(key: String, hop: Int?): Triple<Double, Double, Double>? {
        for ((h, p) in placed) {
            if (hop != null && hop != h) continue
            val ti = p.built.top.indexOf(key)
            val i = if (ti >= 0) ti else p.built.haze.indexOf(key).takeIf { it >= 0 }?.plus(p.built.top.size) ?: continue
            val m = p.m
            val px = p.built.points[3 * i]; val py = p.built.points[3 * i + 1]; val pz = p.built.points[3 * i + 2]
            val out = DoubleArray(4)
            GlobeSphereField.project(m[0] * px + m[1] * py + m[2] * pz, m[3] * px + m[4] * py + m[5] * pz, m[6] * px + m[7] * py + m[8] * pz, out)
            return Triple(p.cx + out[0] * p.r, p.cy + out[1] * p.r, out[3])
        }
        return null
    }
}
