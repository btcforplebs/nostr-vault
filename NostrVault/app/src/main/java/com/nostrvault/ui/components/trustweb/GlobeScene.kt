package com.nostrvault.ui.components

import androidx.compose.runtime.getValue
import androidx.compose.runtime.setValue
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.layout.only
import androidx.compose.runtime.mutableIntStateOf
import androidx.compose.runtime.mutableLongStateOf
import androidx.compose.runtime.mutableStateOf
import androidx.compose.ui.geometry.Offset
import androidx.compose.ui.geometry.Rect
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.Path
import androidx.compose.ui.unit.dp
import com.nostrvault.data.model.GlobeArcs
import com.nostrvault.data.model.GlobeCamera
import com.nostrvault.data.model.GlobeEdge
import com.nostrvault.data.model.GlobeStorm
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
    internal val lite: Boolean = false,
    /** Upright on a phone the globe fills the width; tablets keep their framing. */
    private val phone: Boolean = false,
) {
    enum class Kind { RING, MUTUAL, HAZE, CLOSE_HAZE, BRIDGE, VIA }

    internal class Star(val key: String, val dir: Vec3, var kind: Kind, var radius: Double) {
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
        /** No picture this frame: round the back, or its seat faded out. */
        val ember: Boolean,
        val core: Boolean,
        val tint: Color,
        /** The ember under a face, cross-fading with it at the rim ([GlobeFaceFade]); 0 for none. */
        val emberR: Double = 0.0,
        val emberAlpha: Double = 0.0,
    )

    internal class Projected(val x: Double, val y: Double, val depth: Double, val scale: Double) {
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
    internal var author = ""
    private var me = ""
    private var bridges: List<String> = emptyList()
    private var chains: List<TrustMap.Chain> = emptyList()
    private var faces: List<String> = emptyList()
    /** The core's follows given faces: drawn in the ring's colour. */
    private var ringFaceSet: Set<String> = emptySet()
    /** Faces on the outer shells for the picked layer: drawn in the shell's colour. */
    private var layerFaceSet: Set<String> = emptySet()
    /** With Everyone picked the shells' faces are a small, dim few that give way to your follows' faces. */
    private var dimLayerFaces = false
    /**
     * How far the shells' faces are dimmed and shrunk, easing toward
     * [dimLayerFaces], so a layer change doesn't pop every face's size.
     */
    private var layerDim = 0.0
    /**
     * How brightly your follows, the Close shell and the rest of the shell
     * are drawn, easing toward the picked layer's ([TrustMap.layerWeights]).
     */
    private var weights = TrustMap.Weights(1.0, 1.0, 1.0)
    private var weightTarget = weights
    /**
     * Who the filter icons light, easing from [filterFrom] to [filterTo] as
     * [filterMix] runs 0 to 1. Null lights everyone.
     */
    private var filterFrom: Set<String>? = null
    private var filterTo: Set<String>? = null
    private var filterMix = 1.0
    /** A follow's or a shell's face ring colour, as [Spot.tint] draws it; null for the rest. Re-read on each load. */
    fun shellTint(key: String): Color? {
        version.intValue
        return when {
            traceTarget != null -> null
            key in ringFaceSet -> RingColor
            key in layerFaceSet -> HazeColor
            else -> null
        }
    }
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
    internal var index = HashMap<String, Star>()

    private var born = 0.0
    private var threadsBorn = 0.0
    private var threadProgress = 1.0
    private var settling = false
    /** Each face's seat, fading in and out, and the last frame's step (iOS `seatFade`, `lastDt`). */
    private val seatFades = GlobeSeatFades()
    private var lastDt = 0.0

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

        // Every star's shell and look for this core. [haze] is the core's own
        // web: yours on your globe, theirs on someone else's, so moving onto
        // someone shows their web as if they were you.
        val bridgeSet = frame.bridges.toSet()
        val want = HashMap<String, Pair<Kind, Double>>()
        // Vouched people sit on their own shell, nearer than the rest.
        fun shell(close: Boolean) =
            if (close) Kind.CLOSE_HAZE to TrustMap.CLOSE_RADIUS else Kind.HAZE to TrustMap.OUTER_RADIUS
        // Close is who someone is, not which layer is picked: a Close face past
        // the shell's cap keeps its shell when the layer changes.
        fun wasClose(key: String) = index[key]?.kind == Kind.CLOSE_HAZE
        for (key in haze) want[key] = shell(key in closeHaze)
        // On someone else's globe you're one of the stars.
        if (frame.center != me) want[me] = Kind.BRIDGE to TrustMap.OUTER_RADIUS
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
        for (key in layerFaces) {
            if (key !in want) want[key] = shell(layer == TrustMap.Layer.CLOSE || key in closeHaze || (!newCenter && wasClose(key)))
        }

        for (star in stars) {
            if (star.key !in want) {
                star.radiusTarget = leavingRadius(star.radius, newCenter)
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
        // On someone else's globe you're one of the stars: keep your face.
        if (frame.center != me && taken.add(me)) shown += me
        for (key in TrustMap.spread(bridges, MAX_FACES)) if (taken.add(key)) shown += key
        for (chain in chains.take(TrustMap.SHOWN_CHAINS)) {
            for (key in listOf(chain.bridge, chain.via)) if (taken.add(key)) shown += key
        }
        // Whoever is in the middle, their follows get the faces left over
        // from the paths, so the globe opens with pictures.
        val ringShown = HashSet<String>()
        for (key in ringFaces) if (key in frame.ringSet && taken.add(key)) { shown += key; ringShown += key }
        ringFaceSet = ringShown
        val layerShown = HashSet<String>()
        for (key in layerFaces) if (taken.add(key)) { shown += key; layerShown += key }
        layerFaceSet = layerShown
        dimLayerFaces = layer == TrustMap.Layer.EVERYONE
        // A new globe opens with its faces already the right size.
        if (!hasLoaded) layerDim = layerDimTarget()
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
        val arcOnly = arcs.keys.filter { it !in symbols }
        arcOnlyKeys = arcOnly.toHashSet()
        symbols += arcOnly
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
        val lit = filterWeight(star.key)
        return when (star.kind) {
            Kind.HAZE -> weights.further
            Kind.CLOSE_HAZE -> weights.close
            else -> weights.follows
        } * lit
    }

    private fun filterWeight(key: String): Double {
        fun level(lit: Set<String>?) = if (lit == null || key in lit) 1.0 else FILTERED_OUT
        val to = level(filterTo)
        if (filterMix >= 1) return to
        val from = level(filterFrom)
        return from + (to - from) * filterMix
    }

    /** Lights who the filters match and sets the rest back. Nothing is reloaded. iOS `filter(_:)`. */
    fun filter(lit: Set<String>?) {
        if (lit == filterTo) return
        filterFrom = filterTo
        filterTo = lit
        filterMix = if (Motion.isReduced) 1.0 else 0.0
        wake()
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
        lastDt = dt
        reduceMotion = Motion.isReduced
        // Turned on mid-spin: stop, or the spin never decays and the clock never sleeps.
        if (reduceMotion) camera.spin = Vec3.ZERO
        camera.step(dt, now, reduceMotion)
        if (filterMix < 1) {
            filterMix = min(1.0, filterMix + dt / FILTER_FADE)
            if (filterMix >= 1) filterFrom = null
        }
        val dimTarget = layerDimTarget()
        if (layerDim != dimTarget) {
            layerDim += (dimTarget - layerDim) * (1 - exp(-dt * 8))
            if (abs(dimTarget - layerDim) < 0.005 || reduceMotion) layerDim = dimTarget
        }
        val fading = weights != weightTarget || filterMix < 1 || layerDim != dimTarget || seatFades.fading
        if (weights != weightTarget) {
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
        if (arcs.step(now, me, center)) seatFaces()
        frameCount.longValue++
        val still = !settling && !fading && !camera.wantsFrames(now, reduceMotion)
        // Full rate only under a finger (a drag or pinch, a flick's spin); a
        // storm of arrivals at 60 fps, drift, settling and a few arcs at 30.
        // iOS `GlobeScene.wantedRate`.
        frameRate = GlobeStorm.FrameRate.pick(finger = camera.dragging || !camera.spin.isZero, busy = arcs.busy)
        if (still && arcs.idle) awake = false
    }

    // ── Live arcs (GlobeSceneArcs.kt) ────────────────────────────────

    /** Notes flying across the globe as they reach the relay; on for the WOT tab's globe. */
    internal val arcs = GlobeSceneArcs()
    /** Pictured only as a line's end, not as one of the globe's own faces: drawn white. */
    internal var arcOnlyKeys: Set<String> = emptySet()
    /** How fast the clock runs: full rate under a finger, 60 fps in a storm, else 30 (iOS `frameRate`). */
    var frameRate = GlobeStorm.FrameRate.SLOW
        private set
    /** This frame's projection and scale, for drawing the arcs where the faces are. */
    internal var lastProjector: Projector? = null
    internal var lastK = 1.0

    fun setLiveArcs(on: Boolean) {
        if (arcs.setOn(on)) { seatFaces(); wake() }
    }



    /** Everyone's shell faces are small and dim, unless a filter is lighting them. */
    private fun layerDimTarget() = if (dimLayerFaces && filterTo == null) 1.0 else 0.0

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
    internal class Projector(camera: GlobeCamera, w: Float, h: Float, phone: Boolean) {
        val m = camera.orientation.matrix()
        /** Toward the viewer, in the globe's own space. */
        val facing = Vec3(m[6], m[7], m[8])
        val cameraZ = GlobeCamera.DISTANCE / camera.zoom
        val unit = GlobeCamera.unit(w.toDouble(), h.toDouble(), phone)
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
        val project = Projector(camera, w, h, phone)
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
    internal var dpPx = 1f
    internal var originX = 0.0
    internal var originY = 0.0
    internal var coreR = 0.0
    internal var ready = false

    /** Stars bucketed by kind and brightness: one pass, a few fills. */
    internal val buckets = Array(Slot.entries.size) { Array(LEVELS + 1) { Path() } }
    /** Threads by brightness band, front to back ([GlobeThreads]); each glows in one blurred layer. */
    internal val glow = Array(GlobeThreads.BANDS) { Path() }
    internal val strong = Array(GlobeThreads.BANDS) { Path() }
    internal val faint = Array(GlobeThreads.BANDS) { Path() }
    internal val dashed = Path()
    internal var spots: List<Spot> = emptyList()
    private val spotByKey = HashMap<String, Spot>()

    internal enum class Slot { HAZE, RING, MUTUAL, HOT }

    /** Lite: one slot, brightness and whole-pixel diameter, drawn in a single drawPoints call. */
    internal class PointBucket(val slot: Slot, val level: Int, val diameter: Float) {
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
    internal val pointOrder = ArrayList<PointBucket>()
    internal val pointPaint = android.graphics.Paint().apply {
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

    /** Threads run to someone on this globe, so the glow layer is needed. Compose state: re-read on each load and trace. */
    val threaded: Boolean get() = version.intValue >= 0 && hasLoaded && (traceTarget ?: author) != center

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
        for (band in 0 until GlobeThreads.BANDS) { glow[band].reset(); strong[band].reset(); faint[band].reset() }
        dashed.reset()
        spotByKey.clear()
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
        val project = Projector(camera, w, h, phone)
        val zoom = camera.zoom
        val k = min(1.0, min(w, h) / density / 620.0)
        val core = project.of(coreStar) ?: return
        val origin = project.project(Vec3.ZERO, 0.0) ?: core
        originX = origin.x
        originY = origin.y
        coreR = 22 * k * core.scale * min(zoom, 1.8) * density
        ready = true
        val pad = 8 * density

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
        }

        // Threads: core → bridge → author, drawn out over half a second.
        val authorStar = if (center == author) null else index[author]
        val authorP = authorStar?.let { project.of(it) }
        if (authorP != null) {
            val t = threadProgress
            val leg1 = min(1.0, t * 2)
            val leg2 = max(0.0, t * 2 - 1)
            val top = GlobeThreads.BANDS - 1
            if (direct) {
                strong[top].line(core.x, core.y, lerp(core.x, authorP.x, t), lerp(core.y, authorP.y, t))
                glow[top].line(core.x, core.y, lerp(core.x, authorP.x, t), lerp(core.y, authorP.y, t))
            }
            for (key in bridges) {
                val star = index[key] ?: continue
                if (star.alpha <= 0.05) continue
                val b = project.of(star) ?: continue
                val bandIndex = GlobeThreads.band(b.front)
                val ix = lerp(core.x, b.x, leg1); val iy = lerp(core.y, b.y, leg1)
                faint[bandIndex].line(core.x, core.y, ix, iy)
                glow[bandIndex].line(core.x, core.y, ix, iy)
                if (leg2 > 0) {
                    val ox = lerp(b.x, authorP.x, leg2); val oy = lerp(b.y, authorP.y, leg2)
                    strong[bandIndex].line(b.x, b.y, ox, oy)
                    glow[bandIndex].line(b.x, b.y, ox, oy)
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
        class Drawn(val key: String, val p: Projected, val tint: Color, val size: Double, val dim: Boolean = false)
        val drawn = ArrayList<Drawn>()
        // A filter's matches are the point of the filter, so they never dim.
        val dimLayer = dimLayerFaces && filterTo == null
        for (key in faces) {
            val p = index[key]?.let { project.of(it) } ?: continue
            // iOS: your follows' faces 14 in the ring's colour, the shells' in theirs.
            drawn += when {
                traceTarget == null && key in ringFaceSet -> Drawn(key, p, RingColor, 14.0)
                traceTarget == null && key in layerFaceSet ->
                    Drawn(key, p, HazeColor, 14.0 - 2.0 * layerDim, dimLayer)
                else -> Drawn(key, p, GlobeAccent, 15.0)
            }
        }
        if (authorP != null) drawn += Drawn(author, authorP, AuthorTint, 24.0)
        // Faces the picked layer hides take no seat, so the lit ones get the room.
        drawn.retainAll { face -> index[face.key]?.let { it.alpha * weight(it) > 0.02 } ?: true }
        drawn.sortBy { it.p.depth }

        // Seats: a face only where it covers no other face and not the core;
        // the rest stay stars until the globe turns them some room. Dim faces
        // are seated last and hold no seat, so they never push out a bright one.
        val faceR = { d: Drawn -> d.size * k * d.p.scale * min(zoom, 1.8) * density }
        val front = drawn.asReversed().filter { it.p.depth >= -0.1 || it.key == author }
        val dimKeys = drawn.filter { it.dim }.mapTo(HashSet()) { it.key }
        val seats = TrustMap.seatFaces(
            (front.filter { !it.dim } + front.filter { it.dim })
                .map { TrustMap.FaceSpot(it.key, it.p.x, it.p.y, faceR(it)) },
            always = setOf(author),
            kept = seated - dimKeys,
            blocked = listOf(TrustMap.FaceSpot(center, core.x, core.y, coreR)),
        )
        seated = seats

        // A seat comes and goes over a quarter second, so a face that loses its room
        // cross-fades with its star. Asleep, a seat that changed (a resize) wakes the clock.
        val dt = if (awake) lastDt else 0.0
        seatFades.begin()
        val out = ArrayList<Spot>(drawn.size + 1)
        for (face in drawn) {
            val fade = seatFades.step(face.key, face.key in seats, dt, reduceMotion)
            val a = min(1.0, (index[face.key] ?: coreStar).let { it.alpha * weight(it) })
            val faint = if (traceTarget == null && face.key in layerFaceSet) 1 - (1 - DIM_FACE) * layerDim else 1.0
            val dim = (0.35 + 0.65 * face.p.front) * a * faint
            // Toward the rim a face fades and shrinks onto its ember (iOS GlobeScene.draw).
            val edge = GlobeFaceFade.edge(face.p.depth, face.key == author)
            val shown = edge * fade
            out += Spot(face.key, face.p.x, face.p.y, GlobeEdge.faceRadius(faceR(face), shown),
                GlobeFaceFade.pictureAlpha(dim, shown), face.p.depth,
                ember = shown <= GlobeFaceFade.PICTURE_MIN, core = false, tint = face.tint,
                emberR = GlobeFaceFade.emberRadius(edge, face.p.scale, zoom) * density,
                emberAlpha = GlobeFaceFade.emberAlpha(dim, shown))
        }
        seatFades.end()
        if (seatFades.fading && !awake) wake()
        // The core last: it is always in front of its own shell.
        out += Spot(center, core.x, core.y, coreR, 1.0, core.depth, ember = false, core = true,
            tint = if (center == me) GlobeAccent else Color.White)
        spots = out
        for (spot in out) spotByKey[spot.key] = spot
        lastProjector = project
        lastK = k
        val pictured = seats + center
        for (spot in arcs.faceSpots(lastTick ?: nowSeconds(), { project.project(it, 1.0) }, { key, ring -> arcPoint(key, ring) }, pictured, center) {
            GlobeSceneArcs.faceRadius(it, k, zoom, density)
        }) if (spotByKey[spot.key]?.ember != false) spotByKey[spot.key] = spot
    }

    private fun Path.line(x0: Double, y0: Double, x1: Double, y1: Double) {
        moveTo(x0.toFloat(), y0.toFloat())
        lineTo(x1.toFloat(), y1.toFloat())
    }

    private fun lerp(a: Double, b: Double, t: Double) = a + (b - a) * t

    companion object {
        /** A new globe fades and glides in over this long, then holds still. */
        const val SETTLE_TIME = 1.8
        /** How bright someone a filter leaves out stays: still there, just back. */
        const val FILTERED_OUT = 0.08
        /** Seconds a filter's dimming takes to ease in or out. */
        const val FILTER_FADE = 0.35
        /** How bright Everyone's few faces past your follows are drawn. */
        const val DIM_FACE = 0.8
        /**
         * Star brightness is rounded to this many steps, so each kind of star
         * is a handful of fills however many people there are. Fine enough
         * that the faint haze keeps its front-to-back depth.
         */
        const val LEVELS = 40
        /** Where a star leaving the globe heads when someone else moves into the middle: out past the shells. */
        const val DRIFT_OUT_RADIUS = 2.4

        /**
         * Where a star that is leaving goes, from [radius]. Only a new person in
         * the middle sends it out: a layer or filter change fades it where it
         * is. Out toward the camera a star rushes off the screen and swells, so
         * a hundred of them leaving at once reads as the globe zooming.
         * iOS `TrustMap.leavingRadius`.
         */
        fun leavingRadius(radius: Double, newCenter: Boolean) = if (newCenter) DRIFT_OUT_RADIUS else radius
    }
}
