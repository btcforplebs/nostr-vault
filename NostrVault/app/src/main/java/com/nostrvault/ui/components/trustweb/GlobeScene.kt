package com.nostrvault.ui.components

import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.layout.only
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableIntStateOf
import androidx.compose.runtime.mutableLongStateOf
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.setValue
import androidx.compose.ui.geometry.Offset
import androidx.compose.ui.geometry.Rect
import androidx.compose.ui.graphics.Brush
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.Path
import androidx.compose.ui.graphics.PathEffect
import androidx.compose.ui.graphics.StrokeCap
import androidx.compose.ui.graphics.StrokeJoin
import androidx.compose.ui.graphics.drawscope.DrawScope
import androidx.compose.ui.graphics.drawscope.Stroke
import androidx.compose.ui.graphics.drawscope.drawIntoCanvas
import androidx.compose.ui.graphics.nativeCanvas
import androidx.compose.ui.graphics.toArgb
import androidx.compose.ui.text.TextStyle
import androidx.compose.ui.text.drawText
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.text.TextMeasurer
import androidx.compose.ui.unit.Constraints
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import com.nostrvault.data.model.GlobeCamera
import com.nostrvault.data.model.TrustMap
import com.nostrvault.data.model.Vec3
import com.nostrvault.ui.theme.Motion
import kotlinx.coroutines.flow.drop
import kotlinx.coroutines.flow.first
import kotlin.math.abs
import kotlin.math.exp
import kotlin.math.hypot
import kotlin.math.max
import kotlin.math.min
import kotlin.math.roundToInt

/**
 * Everything the globe draws, kept between frames so a frame is one pass with
 * few allocations. Mutated by the frame clock; only [awake], [faceKeys] and two
 * counters are Compose state.
 */
internal class GlobeScene(
    /** Draw stars as batched points: the oval paths cost a slow phone a whole frame. */
    private val lite: Boolean = false,
) {
    enum class Kind { RING, MUTUAL, HAZE, CLOSE_HAZE, BRIDGE, VIA }

    private class Star(val key: String, val dir: Vec3, var kind: Kind, var radius: Double) {
        var radiusTarget = radius
        var alpha = 0.0
        var alphaTarget = 1.0
        var isFace = false
    }

    /** One person on screen this frame, in pixels. */
    class Spot(
        val key: String,
        val x: Double,
        val y: Double,
        val r: Double,
        val alpha: Double,
        val depth: Double,
        /** Behind the globe: a warm ember, not a face. */
        val ember: Boolean,
        val core: Boolean,
        val tint: Color,
        val label: Boolean,
    )

    private class Projected(val x: Double, val y: Double, val depth: Double, val scale: Double) {
        /** 0 at the back of the globe, 1 at the front. */
        val front: Double get() = ((depth + 1.7) / 3.4).coerceIn(0.0, 1.0)
    }

    /** False once nothing moves: the frame clock stops until a touch or new data. */
    var awake by mutableStateOf(true)
        private set
    /** Who is drawn with a picture: the core, the author, and the faces. */
    var faceKeys by mutableStateOf(emptyList<String>())
        private set
    /** Bumped every tick and every load, so drawing and placement re-run. */
    private val frameCount = mutableLongStateOf(0L)
    private val version = mutableIntStateOf(0)

    val camera = GlobeCamera()
    var lastTick: Double? = null
    var center = ""
        private set
    var hasLoaded = false
        private set
    private var reduceMotion = false
    private var author = ""
    private var me = ""
    private var bridges: List<String> = emptyList()
    private var chains: List<TrustMap.Chain> = emptyList()
    private var faces: List<String> = emptyList()
    /** Faces on the outer shell for the picked layer: drawn in the shell's colour. */
    private var layerFaceSet: Set<String> = emptySet()
    /**
     * How brightly your follows, the Close shell and the rest of the shell
     * are drawn, easing toward the picked layer's ([TrustMap.layerWeights]).
     */
    private var weights = TrustMap.Weights(1.0, 1.0, 1.0)
    private var weightTarget = weights
    /** Faces drawn with a picture last frame, so they keep their seat. */
    private var seated: Set<String> = emptySet()
    private var direct = false
    /** Who the core follows, for a direct thread to the traced person. */
    private var ring: Set<String> = emptySet()
    /**
     * The trust card's person on the WOT tab. The globe stays on you, so they
     * take the author's place: threads run from you through [traceBridges].
     */
    var traceTarget by mutableStateOf<String?>(null)
        private set
    private var traceBridges: List<String> = emptyList()
    /** The traced person and their bridges: lit whatever layer is picked. */
    private var traced: Set<String> = emptySet()
    /** A traced person who had no star of their own (found by search). */
    private var tracedStar: String? = null

    private var stars = ArrayList<Star>()
    private var index = HashMap<String, Star>()

    private var born = 0.0
    private var threadsBorn = 0.0
    private var threadProgress = 1.0
    private var settling = false

    // ── Data ─────────────────────────────────────────────────────────

    fun load(
        frame: TrustFrame,
        me: String,
        author: String,
        myFollows: Set<String>,
        haze: List<String>,
        closeHaze: Set<String> = emptySet(),
        ringFaces: List<String> = emptyList(),
        layerFaces: List<String> = emptyList(),
        layer: TrustMap.Layer = TrustMap.Layer.EVERYONE,
    ) {
        val now = nowSeconds()
        reduceMotion = Motion.isReduced
        val newCenter = !hasLoaded || frame.center != center
        this.me = me
        this.author = author
        center = frame.center

        // Every star's shell and look for this core.
        val bridgeSet = frame.bridges.toSet()
        val want = HashMap<String, Pair<Kind, Double>>()
        if (frame.center == me) for (key in haze) {
            want[key] = (if (key in closeHaze) Kind.CLOSE_HAZE else Kind.HAZE) to TrustMap.OUTER_RADIUS
        }
        for (key in frame.ring) {
            val kind = when {
                key in bridgeSet -> Kind.BRIDGE
                frame.center != me && key in myFollows -> Kind.MUTUAL
                else -> Kind.RING
            }
            want[key] = kind to TrustMap.RING_RADIUS
        }
        for (chain in frame.chains.orEmpty()) {
            if (want[chain.via]?.first != Kind.BRIDGE) want[chain.via] = Kind.VIA to TrustMap.OUTER_RADIUS
        }
        // A bridge the ring snapshot missed (the follow list changed or loaded
        // late) still gets its star and thread.
        for (key in frame.bridges) if (key !in want) want[key] = Kind.BRIDGE to TrustMap.RING_RADIUS
        want[author] = Kind.BRIDGE to TrustMap.AUTHOR_RADIUS
        want[frame.center] = Kind.RING to 0.0
        tracedStar?.let { if (it !in want) want[it] = Kind.BRIDGE to TrustMap.OUTER_RADIUS }
        // A layer's face may be past the shell's cap: it still gets its star.
        if (frame.center == me) {
            val kind = if (layer == TrustMap.Layer.CLOSE) Kind.CLOSE_HAZE else Kind.HAZE
            for (key in layerFaces) if (key !in want) want[key] = kind to TrustMap.OUTER_RADIUS
        }

        for (star in stars) {
            if (star.key !in want) {
                star.radiusTarget = 2.4 // drifts out and fades
                star.alphaTarget = 0.0
            }
        }
        for ((key, look) in want) {
            val (kind, r) = look
            val star = index[key]
            if (star != null) {
                star.kind = kind
                star.radiusTarget = r
                star.alphaTarget = 1.0
            } else {
                val fresh = Star(key, TrustMap.direction(key), kind, r)
                stars.add(fresh)
                index[key] = fresh
            }
        }

        direct = frame.center != author && author in frame.ringSet
        ring = frame.ringSet
        bridges = if (frame.center == author) emptyList() else frame.bridges
        chains = frame.chains.orEmpty()
        val shown = ArrayList<String>()
        val taken = hashSetOf(frame.center, author)
        // The core is the author, so there are no bridges: give the ring faces
        // instead, or there'd be nothing to tap but the core.
        val faceSource = if (frame.center == author) ringFaces.filter { it in frame.ringSet } else TrustMap.spread(bridges, MAX_FACES)
        for (key in faceSource) if (taken.add(key)) shown += key
        for (chain in chains.take(TrustMap.SHOWN_CHAINS)) {
            for (key in listOf(chain.bridge, chain.via)) if (taken.add(key)) shown += key
        }
        val layerShown = HashSet<String>()
        if (frame.center == me) for (key in layerFaces) if (taken.add(key)) { shown += key; layerShown += key }
        layerFaceSet = layerShown
        faces = shown
        seatFaces()

        born = now
        settling = true
        if (newCenter) {
            threadsBorn = now
            threadProgress = if (reduceMotion) 1.0 else 0.0
            val target = GlobeCamera.facing(TrustMap.direction(if (frame.center == author) frame.center else author))
            if (hasLoaded) {
                camera.fly(target, now)
            } else {
                // Opens already turned to show the paths.
                camera.orientation = target
                camera.touch(now)
            }
        }
        hasLoaded = true
        if (reduceMotion) settle()
        version.intValue++
        wake()
    }

    /**
     * Who is drawn with a picture. While a person is traced only they and their
     * bridges are; the rest keep their symbols for when the card closes.
     */
    private fun seatFaces() {
        val symbols = ArrayList((if (center == author) listOf(author) else listOf(center, author)) + faces)
        val target = traceTarget
        val traced = if (target == null) emptyList() else listOf(target) + traceBridges
        for (key in traced) if (key !in symbols) symbols += key
        val pictured = (if (target == null) listOf(author) + faces else traced).toHashSet().apply { add(center) }
        for (star in stars) star.isFace = star.key in pictured
        if (faceKeys != symbols) faceKeys = symbols
    }

    /**
     * Draws the threads from the core to [key] through [bridges], or drops
     * them for null. The core and the author stay where they are.
     */
    fun trace(key: String?, bridges: List<String>) {
        if (!hasLoaded) return
        val target = if (key == center) null else key
        val through = if (target == null) emptyList() else bridges.filter { it != center && it != target }
        if (target == traceTarget && through == traceBridges) return
        val now = nowSeconds()
        tracedStar?.let { old ->
            if (old != target) {
                index[old]?.alphaTarget = 0.0
                tracedStar = null
            }
        }
        if (target != null && target !in index) {
            val fresh = Star(target, TrustMap.direction(target), Kind.BRIDGE, TrustMap.OUTER_RADIUS)
            stars.add(fresh)
            index[target] = fresh
            tracedStar = target
        }
        traceTarget = target
        traceBridges = through
        traced = if (target == null) emptySet() else (listOf(target) + through).toHashSet()
        seatFaces()
        threadsBorn = now
        threadProgress = if (reduceMotion) 1.0 else 0.0
        born = now
        settling = true
        if (reduceMotion) settle()
        version.intValue++
        wake()
    }

    /** Turn toward someone tapped, before their globe has loaded. */
    fun turn(key: String) {
        camera.fly(GlobeCamera.facing(TrustMap.direction(key)), nowSeconds())
        wake()
    }

    fun reset() {
        val target = if (center == author) center else author
        camera.fly(GlobeCamera.facing(TrustMap.direction(target)), nowSeconds())
        wake()
    }

    /** TalkBack's zoom actions. */
    fun zoomStep(step: Double) {
        val range = GlobeCamera.ZOOM_RANGE
        camera.zoomTarget = (camera.zoomTarget + step).coerceIn(range)
        camera.touch(nowSeconds())
        wake()
    }

    /** How brightly [star] is drawn for the picked layer. The core, the author and a traced path are always lit. */
    private fun weight(star: Star): Double {
        if (star.key == center || star.key == author || star.key in traced) return 1.0
        return when (star.kind) {
            Kind.HAZE -> weights.further
            Kind.CLOSE_HAZE -> weights.close
            else -> weights.follows
        }
    }

    /** Lights one layer and hides the rest. Nothing is reloaded. */
    fun focus(layer: TrustMap.Layer) {
        weightTarget = TrustMap.layerWeights(layer)
        if (Motion.isReduced) weights = weightTarget
        wake()
    }

    fun wake() {
        if (!awake) {
            lastTick = null
            awake = true
        }
    }

    /** iOS `onChange(of: reduceMotion)`: drop any spin and redraw once. */
    fun reduceMotionChanged() {
        camera.spin = Vec3.ZERO
        wake()
    }

    // ── Frame clock ──────────────────────────────────────────────────

    fun tick(now: Double) {
        val dt = lastTick?.let { min(GlobeCamera.MAX_STEP, max(0.0, now - it)) } ?: 0.0
        lastTick = now
        reduceMotion = Motion.isReduced
        // Turned on mid-spin: stop, or the spin never decays and the clock never sleeps.
        if (reduceMotion) camera.spin = Vec3.ZERO
        camera.step(dt, now, reduceMotion)
        val fading = weights != weightTarget
        if (fading) {
            val ease = 1 - exp(-dt * 8)
            fun step(from: Double, to: Double) = if (abs(to - from) < 0.005) to else from + (to - from) * ease
            weights = TrustMap.Weights(
                step(weights.follows, weightTarget.follows),
                step(weights.close, weightTarget.close),
                step(weights.further, weightTarget.further),
            )
            frameCount.longValue++
        }
        if (settling) {
            val age = now - born
            val glide = 1 - exp(-dt * 7)
            val fade = 1 - exp(-dt * 6)
            for (star in stars) {
                star.radius += (star.radiusTarget - star.radius) * glide
                // Sweep in by direction so the shell fills like a wave, not a pop.
                if (age > (star.dir.x + 1) * 0.12) star.alpha += (star.alphaTarget - star.alpha) * fade
            }
            threadProgress = ((now - threadsBorn - 0.35) / 0.55).coerceIn(0.0, 1.0)
            if (age > SETTLE_TIME) settle()
        }
        frameCount.longValue++
        if (!settling && !fading && !camera.wantsFrames(now, reduceMotion)) awake = false
    }

    /** Land every star where it's heading and drop the ones that faded out. */
    private fun settle() {
        for (star in stars) {
            star.radius = star.radiusTarget
            star.alpha = star.alphaTarget
        }
        threadProgress = 1.0
        settling = false
        if (stars.all { it.alphaTarget > 0 }) return
        stars = stars.filterTo(ArrayList()) { it.alphaTarget > 0 }
        index = stars.associateByTo(HashMap()) { it.key }
    }

    // ── Projection ───────────────────────────────────────────────────

    /** One camera's projection, worked out once per frame. */
    private class Projector(camera: GlobeCamera, w: Float, h: Float) {
        val m = camera.orientation.matrix()
        val cameraZ = 4.2 / camera.zoom
        val unit = min(w, h) * 0.40 * 4.2 * 0.92
        val midX = w / 2.0
        val midY = h / 2.0

        fun project(d: Vec3, r: Double): Projected? {
            val px = d.x * r; val py = d.y * r; val pz = d.z * r
            val vx = m[0] * px + m[1] * py + m[2] * pz
            val vy = m[3] * px + m[4] * py + m[5] * pz
            val vz = m[6] * px + m[7] * py + m[8] * pz
            val gap = cameraZ - vz
            // Zoomed in, the outer shell passes the camera: drop what's behind the lens.
            if (gap < 0.45) return null
            val s = 1 / gap
            return Projected(midX + vx * s * unit, midY - vy * s * unit, vz, s * cameraZ)
        }
    }

    private fun Projector.of(star: Star) = project(star.dir, star.radius)

    /** Closest front-facing face to a tap, within reach of a fingertip. Zoomed in, plain stars can be tapped too. */
    fun hit(at: Offset, w: Float, h: Float, density: Float): String? {
        val project = Projector(camera, w, h)
        var best: String? = null
        var bestDistance = Double.MAX_VALUE
        fun consider(star: Star, reach: Double) {
            if (star.alpha * min(1.0, weight(star)) <= 0.5) return
            val p = project.of(star) ?: return
            if (p.depth <= -0.15) return
            val d = hypot(p.x - at.x, p.y - at.y)
            if (d < reach && d < bestDistance) { best = star.key; bestDistance = d }
        }
        for (star in stars) if (star.isFace) consider(star, 30.0 * density)
        if (best == null && camera.zoom >= 1.6) {
            for (star in stars) if (!star.isFace && star.kind != Kind.HAZE && star.kind != Kind.CLOSE_HAZE) consider(star, 16.0 * density)
        }
        return best
    }

    // ── One frame's picture ──────────────────────────────────────────

    private var preparedFor = LongArray(4) { -1 }
    /** Pixels per dp for the frame last prepared. */
    private var dpPx = 1f
    private var originX = 0.0
    private var originY = 0.0
    private var coreR = 0.0
    private var ready = false

    /** Stars bucketed by kind and brightness: one pass, a few fills. */
    private val buckets = Array(Slot.entries.size) { Array(LEVELS + 1) { Path() } }
    private val glow = Array(4) { Path() }
    private val strong = Array(4) { Path() }
    private val faint = Array(4) { Path() }
    private val dashed = Path()
    private var spots: List<Spot> = emptyList()
    private val spotByKey = HashMap<String, Spot>()
    private val starLabels = ArrayList<Spot>()

    private enum class Slot { HAZE, RING, MUTUAL, HOT }

    /** Lite: one slot, brightness and whole-pixel diameter, drawn in a single drawPoints call. */
    private class PointBucket(val slot: Slot, val level: Int, val diameter: Float) {
        var xy = FloatArray(64)
        var count = 0
        fun add(x: Float, y: Float) {
            if (count * 2 + 2 > xy.size) xy = xy.copyOf(xy.size * 2)
            xy[count * 2] = x
            xy[count * 2 + 1] = y
            count++
        }
    }
    /** Kept between frames and emptied, so a frame allocates nothing once warm. */
    private val pointBuckets = HashMap<Int, PointBucket>()
    private val pointOrder = ArrayList<PointBucket>()
    private val pointPaint = android.graphics.Paint().apply {
        isAntiAlias = true
        strokeCap = android.graphics.Paint.Cap.ROUND
        style = android.graphics.Paint.Style.STROKE
    }

    private fun pointBucket(slot: Slot, level: Int, radius: Double): PointBucket {
        val diameter = max(1, (radius * 2).roundToInt()).coerceAtMost(255)
        val key = (slot.ordinal shl 16) or (level shl 8) or diameter
        return pointBuckets.getOrPut(key) {
            PointBucket(slot, level, diameter.toFloat()).also {
                pointOrder.add(it)
                // Dim to bright, as the oval fills go, so a bright star sits on top.
                pointOrder.sortWith(compareBy({ b -> b.level }, { b -> b.diameter }))
            }
        }
    }

    fun spot(key: String): Spot? = spotByKey[key]

    /**
     * Works out this frame's stars, threads and faces for a [w]×[h] pixel
     * view. Runs once per frame however many times it's asked: placement
     * asks first, then both canvases.
     */
    fun prepare(w: Float, h: Float, density: Float) {
        val f = frameCount.longValue
        val v = version.intValue.toLong()
        val key = longArrayOf(f, v, w.toRawBits().toLong(), h.toRawBits().toLong())
        if (key.contentEquals(preparedFor)) return
        preparedFor = key
        dpPx = density
        for (slot in buckets) for (p in slot) p.reset()
        for (bucket in pointBuckets.values) bucket.count = 0
        for (band in 0 until 4) { glow[band].reset(); strong[band].reset(); faint[band].reset() }
        dashed.reset()
        spotByKey.clear()
        starLabels.clear()
        spots = emptyList()
        ready = false

        val coreStar = index[center]
        if (!hasLoaded || coreStar == null) return
        // The trust card's person, if any, takes the author's place.
        val author = traceTarget ?: this.author
        val bridges = if (traceTarget == null) this.bridges else traceBridges
        val chains = if (traceTarget == null) this.chains else emptyList()
        val faces = if (traceTarget == null) this.faces else traceBridges
        val direct = traceTarget?.let { it in ring } ?: this.direct
        val project = Projector(camera, w, h)
        val zoom = camera.zoom
        val k = min(1.0, min(w, h) / density / 620.0)
        val core = project.of(coreStar) ?: return
        val origin = project.project(Vec3.ZERO, 0.0) ?: core
        originX = origin.x
        originY = origin.y
        coreR = 22 * k * core.scale * min(zoom, 1.8) * density
        ready = true
        val pad = 8 * density
        val namesOut = zoom > 2.2
        val labelled = ArrayList<Spot>()

        for (star in stars) {
            if (star.isFace) continue
            val a = star.alpha * weight(star)
            if (a <= 0.02) continue
            val p = project.of(star) ?: continue
            if (p.x < -pad || p.y < -pad || p.x > w + pad || p.y > h + pad) continue
            val front = p.front
            val (slot, base, size) = when (star.kind) {
                Kind.HAZE -> Triple(Slot.HAZE, 0.06 + 0.16 * front, 1.2)
                // A touch brighter and bigger: close enough to tell apart in the shell.
                Kind.CLOSE_HAZE -> Triple(Slot.HAZE, 0.10 + 0.22 * front, 1.4)
                Kind.RING -> Triple(Slot.RING, 0.25 + 0.65 * front, 2.1)
                Kind.MUTUAL -> Triple(Slot.MUTUAL, 0.45 + 0.55 * front, 2.4)
                Kind.BRIDGE, Kind.VIA -> Triple(Slot.HOT, 0.35 + 0.65 * front, 2.8)
            }
            val level = (min(1.0, base * a) * LEVELS).roundToInt()
            if (level <= 0) continue
            val r = size * p.scale * zoom * density
            if (lite) {
                pointBucket(slot, min(LEVELS, level), r).add(p.x.toFloat(), p.y.toFloat())
            } else {
                buckets[slot.ordinal][min(LEVELS, level)].addOval(
                    Rect((p.x - r).toFloat(), (p.y - r).toFloat(), (p.x + r).toFloat(), (p.y + r).toFloat()),
                )
            }
            if (namesOut && slot != Slot.HAZE && p.depth > 0.6 && labelled.size < 200) {
                labelled += Spot(star.key, p.x, p.y, r, a, p.depth, ember = false, core = false, tint = Color.White, label = true)
            }
        }

        // Threads: core → bridge → author, drawn out over half a second.
        val authorStar = if (center == author) null else index[author]
        val authorP = authorStar?.let { project.of(it) }
        if (authorP != null) {
            val t = threadProgress
            val leg1 = min(1.0, t * 2)
            val leg2 = max(0.0, t * 2 - 1)
            fun band(front: Double) = min(3, (front * 4).toInt())
            if (direct) {
                strong[3].line(core.x, core.y, lerp(core.x, authorP.x, t), lerp(core.y, authorP.y, t))
                glow[3].line(core.x, core.y, lerp(core.x, authorP.x, t), lerp(core.y, authorP.y, t))
            }
            for (key in bridges) {
                val star = index[key] ?: continue
                if (star.alpha <= 0.05) continue
                val b = project.of(star) ?: continue
                val bandIndex = band(b.front)
                val ix = lerp(core.x, b.x, leg1); val iy = lerp(core.y, b.y, leg1)
                faint[bandIndex].line(core.x, core.y, ix, iy)
                val bright = b.front > 0.62
                if (bright) glow[bandIndex].line(core.x, core.y, ix, iy)
                if (leg2 > 0) {
                    val ox = lerp(b.x, authorP.x, leg2); val oy = lerp(b.y, authorP.y, leg2)
                    strong[bandIndex].line(b.x, b.y, ox, oy)
                    if (bright) glow[bandIndex].line(b.x, b.y, ox, oy)
                }
            }
            if (t >= 1) {
                for (chain in chains) {
                    val b = index[chain.bridge]?.let { project.of(it) } ?: continue
                    val via = index[chain.via]?.let { project.of(it) } ?: continue
                    dashed.moveTo(core.x.toFloat(), core.y.toFloat())
                    dashed.lineTo(b.x.toFloat(), b.y.toFloat())
                    dashed.lineTo(via.x.toFloat(), via.y.toFloat())
                    dashed.lineTo(authorP.x.toFloat(), authorP.y.toFloat())
                }
            }
        }

        // Faces, back to front: bridges, chain steps and the author.
        class Drawn(val key: String, val p: Projected, val tint: Color, val size: Double)
        val drawn = ArrayList<Drawn>()
        for (key in faces) {
            val p = index[key]?.let { project.of(it) } ?: continue
            drawn += when {
                traceTarget == null && key in layerFaceSet -> Drawn(key, p, HazeColor, 14.0)
                center == author && traceTarget == null -> Drawn(key, p, RingColor, 15.0)
                else -> Drawn(key, p, GlobeAccent, 15.0)
            }
        }
        if (authorP != null) drawn += Drawn(author, authorP, AuthorTint, 24.0)
        // Faces the picked layer hides take no seat, so the lit ones get the room.
        drawn.retainAll { face -> index[face.key]?.let { it.alpha * weight(it) > 0.02 } ?: true }
        drawn.sortBy { it.p.depth }

        // Seats: a face only where it covers no other face and not the core;
        // the rest stay stars until the globe turns them some room.
        val faceR = { d: Drawn -> d.size * k * d.p.scale * min(zoom, 1.8) * density }
        val seats = TrustMap.seatFaces(
            drawn.asReversed().filter { it.p.depth >= -0.1 || it.key == author }
                .map { TrustMap.FaceSpot(it.key, it.p.x, it.p.y, faceR(it)) },
            always = setOf(author),
            kept = seated,
            blocked = listOf(TrustMap.FaceSpot(center, core.x, core.y, coreR)),
        )
        seated = seats

        // Labels: front-most first, skipping any that would cover one placed.
        val placed = arrayListOf(Rect((core.x - 40 * density).toFloat(), (core.y - coreR).toFloat(),
            (core.x + 40 * density).toFloat(), (core.y + coreR + 22 * density).toFloat()))
        // Pictures count as placed too, so a name never runs across a face.
        for (face in drawn) {
            if (face.key !in seats) continue
            val r = faceR(face)
            placed += Rect((face.p.x - r).toFloat(), (face.p.y - r).toFloat(), (face.p.x + r).toFloat(), (face.p.y + r).toFloat())
        }
        val showLabel = HashSet<String>()
        val labelCap = if (zoom < 1.5) 9 else 40
        for (face in drawn.asReversed()) {
            if (face.p.depth <= 0.15 || face.key !in seats || showLabel.size >= labelCap) continue
            val r = face.size * k * face.p.scale * min(zoom, 1.8) * density
            val box = Rect((face.p.x - 46 * density).toFloat(), (face.p.y + r + 2 * density).toFloat(),
                (face.p.x + 46 * density).toFloat(), (face.p.y + r + 18 * density).toFloat())
            if (face.key == author || placed.none { it.overlaps(box) }) {
                placed += box
                showLabel += face.key
            }
        }
        val out = ArrayList<Spot>(drawn.size + 1)
        for (face in drawn) {
            val a = min(1.0, (index[face.key] ?: coreStar).let { it.alpha * weight(it) })
            val dim = (0.35 + 0.65 * face.p.front) * a
            val behind = face.p.depth < -0.1 && face.key != author
            // No room for its picture here: a bright star in its colour.
            val held = !behind && face.key !in seats
            val r = if (behind) 3.2 * face.p.scale * zoom * density
            else if (held) 3.6 * face.p.scale * zoom * density
            else faceR(face)
            out += Spot(face.key, face.p.x, face.p.y, r, dim, face.p.depth, ember = behind || held, core = false,
                tint = face.tint, label = face.key in showLabel)
        }
        // The core last: it is always in front of its own shell.
        out += Spot(center, core.x, core.y, coreR, 1.0, core.depth, ember = false, core = true,
            tint = if (center == me) GlobeAccent else Color.White, label = true)
        spots = out
        for (spot in out) spotByKey[spot.key] = spot

        // Names on plain stars once zoomed well in, where they fit.
        if (namesOut) {
            for (star in labelled) {
                if (placed.size >= 60) break
                val box = Rect((star.x - 40 * density).toFloat(), (star.y + star.r + 2 * density).toFloat(),
                    (star.x + 40 * density).toFloat(), (star.y + star.r + 15 * density).toFloat())
                if (placed.any { it.overlaps(box) }) continue
                placed += box
                starLabels += star
            }
        }
    }

    /** Stars, threads, glows and embers: everything under the faces. */
    fun drawBack(scope: DrawScope, accent: Color) = with(scope) {
        prepare(size.width, size.height, density)
        if (!ready) return@with
        val dp = dpPx

        // Glow behind the core.
        val glowR = (coreR * 3).toFloat()
        if (glowR > 0f) {
            drawCircle(
                brush = Brush.radialGradient(listOf(accent.copy(alpha = 0.32f), Color.Transparent),
                    center = Offset(originX.toFloat(), originY.toFloat()), radius = glowR),
                radius = glowR,
                center = Offset(originX.toFloat(), originY.toFloat()),
            )
        }

        fun fill(slot: Slot, color: Color) {
            if (lite) {
                drawIntoCanvas { canvas ->
                    for (bucket in pointOrder) {
                        if (bucket.slot != slot || bucket.count == 0) continue
                        pointPaint.color = color.copy(alpha = bucket.level.toFloat() / LEVELS).toArgb()
                        pointPaint.strokeWidth = bucket.diameter
                        canvas.nativeCanvas.drawPoints(bucket.xy, 0, bucket.count * 2, pointPaint)
                    }
                }
                return
            }
            for (level in 1..LEVELS) {
                val path = buckets[slot.ordinal][level]
                if (!path.isEmpty) drawPath(path, color.copy(alpha = level.toFloat() / LEVELS))
            }
        }
        fill(Slot.HAZE, HazeColor)
        fill(Slot.RING, RingColor)
        fill(Slot.MUTUAL, Color.White)

        // Glow brightens toward the front. No blur on every Android version,
        // so two soft strokes stand in for iOS's blurred layer.
        fun bandAlpha(level: Int): Float {
            val front = (level + 0.5f) / 4
            return 0.10f + 0.75f * front * front
        }
        for (level in 0 until 4) {
            if (glow[level].isEmpty) continue
            val a = bandAlpha(level) * 0.6f
            drawPath(glow[level], accent.copy(alpha = a * 0.25f), style = Stroke(width = 8 * dp, cap = StrokeCap.Round))
            drawPath(glow[level], accent.copy(alpha = a * 0.45f), style = Stroke(width = 4 * dp, cap = StrokeCap.Round))
        }
        for (level in 0 until 4) {
            val a = bandAlpha(level)
            if (!faint[level].isEmpty) drawPath(faint[level], ThreadColor.copy(alpha = a * 0.45f), style = Stroke(width = 0.8f * dp))
            if (!strong[level].isEmpty) drawPath(strong[level], ThreadColor.copy(alpha = a), style = Stroke(width = 1.3f * dp))
        }
        if (!dashed.isEmpty) {
            drawPath(dashed, ThreadColor.copy(alpha = 0.7f), style = Stroke(width = 1.2f * dp, cap = StrokeCap.Round,
                join = StrokeJoin.Round, pathEffect = PathEffect.dashPathEffect(floatArrayOf(5 * dp, 4 * dp))))
        }
        fill(Slot.HOT, accent)

        // A soft tint behind each face, and embers for those behind the globe.
        for (spot in spots) {
            val c = Offset(spot.x.toFloat(), spot.y.toFloat())
            if (spot.ember) {
                drawCircle(accent.copy(alpha = spot.alpha.toFloat().coerceIn(0f, 1f)), radius = spot.r.toFloat(), center = c)
                continue
            }
            val r = spot.r.toFloat()
            if (r <= 0f) continue
            drawCircle(
                brush = Brush.radialGradient(
                    0.6f / 1.9f to spot.tint.copy(alpha = 0.35f * spot.alpha.toFloat()),
                    1f to Color.Transparent,
                    center = c, radius = r * 1.9f,
                ),
                radius = r * 1.9f,
                center = c,
            )
        }
    }

    /** Names under the faces, the core, and plain stars once zoomed in. */
    fun drawLabels(scope: DrawScope, measurer: TextMeasurer, name: (String) -> String) = with(scope) {
        prepare(size.width, size.height, density)
        if (!ready) return@with
        val dp = dpPx
        fun label(text: String, x: Double, y: Double, sizeSp: Float, weight: FontWeight, alpha: Float) {
            val layout = measurer.measure(
                text,
                TextStyle(color = Color.White, fontSize = sizeSp.sp, fontWeight = weight),
                maxLines = 1,
                overflow = TextOverflow.Ellipsis,
                constraints = Constraints(maxWidth = (120 * dp).roundToInt()),
            )
            drawText(layout, topLeft = Offset((x - layout.size.width / 2.0).toFloat(), (y - layout.size.height / 2.0).toFloat()),
                alpha = alpha.coerceIn(0f, 1f))
        }
        for (spot in spots) {
            if (spot.core || spot.ember || !spot.label) continue
            val isAuthor = spot.key == (traceTarget ?: author)
            label(name(spot.key), spot.x, spot.y + spot.r + 10 * dp, if (isAuthor) 14f else 11f, FontWeight.SemiBold,
                (0.9 * spot.alpha).toFloat())
        }
        for (star in starLabels) {
            label(name(star.key), star.x, star.y + star.r + 8 * dp, 10f, FontWeight.Normal, (0.6 * star.alpha).toFloat())
        }
        spots.lastOrNull()?.takeIf { it.core }?.let { core ->
            label(name(core.key), core.x, core.y + core.r + 11 * dp, 13f, FontWeight.Bold, 1f)
        }
    }

    private fun Path.line(x0: Double, y0: Double, x1: Double, y1: Double) {
        moveTo(x0.toFloat(), y0.toFloat())
        lineTo(x1.toFloat(), y1.toFloat())
    }

    private fun lerp(a: Double, b: Double, t: Double) = a + (b - a) * t

    companion object {
        /** A new globe fades and glides in over this long, then holds still. */
        const val SETTLE_TIME = 1.8
        /**
         * Star brightness is rounded to this many steps, so each kind of star
         * is a handful of fills however many people there are. Fine enough
         * that the faint haze keeps its front-to-back depth.
         */
        const val LEVELS = 40
    }
}
